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

# Update package lists
echo "Updating package lists..."
apt update || error_exit "apt update failed."

# Upgrade all packages
echo "Upgrading packages..."
apt full-upgrade -y || error_exit "apt full-upgrade failed."

# Install mtools and dos2unix
echo "Installing mtools and dos2unix..."
apt install mtools dos2unix -y || error_exit "Package installation failed."

echo "All operations completed successfully."

# Set your desired USB image label (FAT32 label limit: 11 characters, uppercase, no spaces)
USB_IMAGE_LABEL="PIUSB"

# Validate USB_IMAGE_LABEL length and characters
if [ ${#USB_IMAGE_LABEL} -gt 11 ] || [[ ! "$USB_IMAGE_LABEL" =~ ^[A-Z0-9_]+$ ]]; then
    error_exit "USB_IMAGE_LABEL must be up to 11 uppercase letters, numbers, or underscores."
fi

# Define the USB image file path
USB_IMAGE_FILE="/piusb.bin"

# Set the size as appropriate (in megabytes)
USB_SIZE_MB=256  # Adjust this value as needed

echo "USB Image Label: $USB_IMAGE_LABEL"
echo "USB Image Size: ${USB_SIZE_MB}MB"

# Enable dwc2 overlay in /boot/firmware/config.txt if not already enabled
CONFIG_TXT="/boot/firmware/config.txt"

if ! grep -q "^dtoverlay=dwc2,dr_mode=peripheral" "$CONFIG_TXT"; then
    echo "Configuring dwc2 overlay in $CONFIG_TXT..."
    cp "$CONFIG_TXT" "$CONFIG_TXT.bak"
    sed -i '/^[^#]*dtoverlay=dwc2/s/^/#/' "$CONFIG_TXT"
    echo "dtoverlay=dwc2,dr_mode=peripheral" >> "$CONFIG_TXT" || error_exit "Failed to modify $CONFIG_TXT."
fi

# Ensure 'dwc2' and 'g_mass_storage' modules are in /etc/modules
MODULES_FILE="/etc/modules"
for module in dwc2 g_mass_storage; do
    if ! grep -q "^$module$" "$MODULES_FILE"; then
        echo "Adding $module to $MODULES_FILE..."
        echo "$module" >> "$MODULES_FILE" || error_exit "Failed to add $module to $MODULES_FILE."
    else
        echo "$module is already present in $MODULES_FILE."
    fi
done

# Create modprobe configuration for g_mass_storage
G_MASS_STORAGE_CONF="/etc/modprobe.d/g_mass_storage.conf"
echo "Configuring g_mass_storage module parameters..."
echo "options g_mass_storage file=$USB_IMAGE_FILE removable=1 ro=0 stall=0" > "$G_MASS_STORAGE_CONF" || error_exit "Failed to create $G_MASS_STORAGE_CONF."

# Reload systemd and modprobe configurations
echo "Reloading configurations..."
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
depmod -a || error_exit "Failed to reload modprobe configurations."

# Remove existing USB image if it exists
if [ -f "$USB_IMAGE_FILE" ]; then
    echo "Removing existing USB image $USB_IMAGE_FILE..."
    modprobe -r g_mass_storage || true  # Remove if already loaded
    rm -f "$USB_IMAGE_FILE" || error_exit "Failed to remove existing USB image."
fi

# Create the USB image file with specified size
echo "Creating USB image file $USB_IMAGE_FILE..."
dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count="$USB_SIZE_MB" status=progress || error_exit "Failed to create USB image file."

# Format the USB image with FAT32 filesystem
echo "Formatting $USB_IMAGE_FILE with FAT32 filesystem..."
mkdosfs -F 32 -n "$USB_IMAGE_LABEL" "$USB_IMAGE_FILE" || error_exit "Failed to format USB image file."

# Set permissions on the USB image file
chmod 666 "$USB_IMAGE_FILE" || error_exit "Failed to set permissions on USB image file."

# Load the g_mass_storage module with the USB image
echo "Loading g_mass_storage module with $USB_IMAGE_FILE..."
modprobe -r g_mass_storage || true
modprobe g_mass_storage || error_exit "Failed to load g_mass_storage module."

# Define the path to the mtools configuration file
CONFIG_FILE="/home/pi/.mtoolsrc"

# Ensure the configuration file exists
touch "$CONFIG_FILE"

# Add lines if they are not already present
grep -qxF 'drive p: file="/piusb.bin" exclusive' "$CONFIG_FILE" || echo 'drive p: file="/piusb.bin" exclusive' >> "$CONFIG_FILE"
grep -qxF 'mtools_skip_check=1' "$CONFIG_FILE" || echo 'mtools_skip_check=1' >> "$CONFIG_FILE"

echo "mtools configuration updated in $CONFIG_FILE."

# Final message and reboot
echo ""
echo "USB mass storage setup is complete."
echo "The system will reboot now to apply changes."
echo "=========================================================="
echo ""
reboot now
