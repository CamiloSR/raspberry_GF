#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to display error messages
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo ""
    echo "_______________________________"
    echo "Please use sudo or run as root."
    echo "==============================="
    echo ""
    exit 1
fi

# Set your desired USB image label here (FAT32 label limit: 11 characters, uppercase, no spaces)
USB_IMAGE_LABEL="ABGAMMA1"

# Validate USB_IMAGE_LABEL length
if [ ${#USB_IMAGE_LABEL} -gt 11 ]; then
    error_exit "USB_IMAGE_LABEL must be 11 characters or fewer."
fi

# Validate USB_IMAGE_LABEL characters
if [[ ! "$USB_IMAGE_LABEL" =~ ^[A-Z0-9_]+$ ]]; then
    error_exit "USB_IMAGE_LABEL must contain only uppercase letters, numbers, and underscores."
fi

# Define the USB image file path
USB_IMAGE_FILE="/piusb.bin"

# Set the size as appropriate (in megabytes)
USB_SIZE_MB=2048  # Adjust this value as needed

echo "USB Image Label: $USB_IMAGE_LABEL"
echo "USB Image Size: ${USB_SIZE_MB}MB"

# Enable dwc2 overlay in /boot/firmware/config.txt if not already enabled
CONFIG_TXT="/boot/firmware/config.txt"

# Check if dtoverlay=dwc2 exists under [all] section with dr_mode=peripheral
if ! awk '/\[all\]/ {in_all=1} in_all && /^dtoverlay=dwc2,dr_mode=peripheral/ {found=1; exit} END {exit !found}' "$CONFIG_TXT"; then
    echo "Configuring dwc2 overlay under [all] in $CONFIG_TXT..."

    # Backup config.txt before modification
    cp "$CONFIG_TXT" "$CONFIG_TXT.bak"

    # Comment out any existing `dtoverlay=dwc2` lines not already commented
    sed -i '/^[^#]*dtoverlay=dwc2/s/^/#/' "$CONFIG_TXT"

    # Ensure [all] section exists, then add `dtoverlay=dwc2,dr_mode=peripheral` under it
    if ! grep -q "^\[all\]" "$CONFIG_TXT"; then
        echo "[all]" >> "$CONFIG_TXT"
    fi

    # Append `dtoverlay=dwc2,dr_mode=peripheral` under [all]
    sed -i '/^\[all\]/a dtoverlay=dwc2,dr_mode=peripheral' "$CONFIG_TXT" || error_exit "Failed to modify $CONFIG_TXT."
fi

# Ensure 'dwc2' and 'g_mass_storage' modules are in /etc/modules
MODULES_FILE="/etc/modules"
MODULES=("dwc2" "g_mass_storage")

for module in "${MODULES[@]}"; do
    if ! grep -q "^$module$" "$MODULES_FILE"; then
        echo "Adding $module to $MODULES_FILE..."
        echo "$module" >> "$MODULES_FILE" || error_exit "Failed to add $module to $MODULES_FILE."
    else
        echo "$module is already present in $MODULES_FILE."
    fi
done

# Create a modprobe configuration file for g_mass_storage to ensure parameters persist across reboots
G_MASS_STORAGE_CONF="/etc/modprobe.d/g_mass_storage.conf"

echo "Configuring g_mass_storage module parameters..."
echo "options g_mass_storage file=$USB_IMAGE_FILE stall=0 removable=1 ro=0" > "$G_MASS_STORAGE_CONF" || error_exit "Failed to create $G_MASS_STORAGE_CONF."

# Reload systemd and modprobe configurations
echo "Reloading systemd daemon to apply configuration changes..."
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."

echo "Reloading modprobe configurations..."
depmod -a || error_exit "Failed to reload modprobe configurations."

# Remove existing USB image if it exists
if [ -f "$USB_IMAGE_FILE" ]; then
    echo "Removing existing USB image $USB_IMAGE_FILE..."
    # Unload g_mass_storage module if loaded
    if lsmod | grep -q "g_mass_storage"; then
        echo "Unloading g_mass_storage module..."
        modprobe -r g_mass_storage || error_exit "Failed to unload g_mass_storage module."
    fi
    rm -f "$USB_IMAGE_FILE" || error_exit "Failed to remove existing USB image."
fi

# Create the USB image file with specified size
echo "Creating USB image file $USB_IMAGE_FILE..."
dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count="$USB_SIZE_MB" status=progress || error_exit "Failed to create USB image file."

# Format the USB image with FAT32 filesystem
echo "Formatting $USB_IMAGE_FILE with FAT32 filesystem..."
mkdosfs -F 32 --mbr=yes -n "$USB_IMAGE_LABEL" "$USB_IMAGE_FILE" || error_exit "Failed to format USB image file."

# Set appropriate permissions on the USB image file
chmod 666 "$USB_IMAGE_FILE" || error_exit "Failed to set permissions on USB image file."

# Install mtools
echo "Installing mtools..."
apt-get update || error_exit "Failed to update package lists."
apt-get install -y mtools || error_exit "Failed to install mtools."

# Configure mtools to access the USB image file
MTOOLSRC="/root/.mtoolsrc"
echo "Configuring mtools..."
echo "drive p: file=\"$USB_IMAGE_FILE\" exclusive" > "$MTOOLSRC" || error_exit "Failed to create $MTOOLSRC."
chmod 600 "$MTOOLSRC" || error_exit "Failed to set permissions on $MTOOLSRC."

# Load the g_mass_storage module with the USB image
echo "Loading g_mass_storage module with $USB_IMAGE_FILE..."
modprobe -r g_mass_storage || true  # Remove if already loaded
modprobe g_mass_storage || error_exit "Failed to load g_mass_storage module."

# Final message and reboot
echo ""
echo "USB mass storage setup is complete."
echo "The system will reboot now to apply changes."
echo "=========================================================="
echo ""
reboot now
