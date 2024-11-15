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

# Install mtools
echo "Installing mtools..."
apt install mtools -y || error_exit "apt install mtools failed."

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
    # Unmount if mounted
    if mount | grep -q "$USB_IMAGE_FILE"; then
        echo "Unmounting $USB_IMAGE_FILE..."
        umount "$USB_IMAGE_FILE" || error_exit "Failed to unmount $USB_IMAGE_FILE."
    fi
    rm -f "$USB_IMAGE_FILE" || error_exit "Failed to remove existing USB image."
fi

# Create the USB image file with specified size
echo "Creating USB image file $USB_IMAGE_FILE..."
dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count="$USB_SIZE_MB" status=progress || error_exit "Failed to create USB image file."

# Format the USB image with FAT32 filesystem
echo "Formatting $USB_IMAGE_FILE with FAT32 filesystem..."
mkdosfs -F 32 --mbr=yes -n "$USB_IMAGE_LABEL" "$USB_IMAGE_FILE" || error_exit "Failed to format USB image file."

# Remove any existing mount point
MOUNT_POINT="/mnt/$(echo "$USB_IMAGE_LABEL" | tr '[:upper:]' '[:lower:]')"
if mount | grep -q "$MOUNT_POINT"; then
    echo "Unmounting existing mount point $MOUNT_POINT..."
    umount "$MOUNT_POINT" || error_exit "Failed to unmount $MOUNT_POINT."
fi

# Remove existing mount point directory if exists
if [ -d "$MOUNT_POINT" ]; then
    echo "Removing existing mount point directory $MOUNT_POINT..."
    rm -rf "$MOUNT_POINT" || error_exit "Failed to remove $MOUNT_POINT."
fi

# Create the mount point directory
echo "Creating mount point directory $MOUNT_POINT..."
mkdir -p "$MOUNT_POINT" || error_exit "Failed to create mount point directory."

# Mount the USB image file
echo "Mounting $USB_IMAGE_FILE to $MOUNT_POINT..."
mount -o loop,ro "$USB_IMAGE_FILE" "$MOUNT_POINT" || error_exit "Failed to mount USB image file."

# Unmount to avoid simultaneous access
echo "Unmounting $USB_IMAGE_FILE from $MOUNT_POINT to prevent conflicts..."
umount "$MOUNT_POINT" || error_exit "Failed to unmount USB image file."

# Load the g_mass_storage module with the USB image
echo "Loading g_mass_storage module with $USB_IMAGE_FILE..."
modprobe -r g_mass_storage || true  # Remove if already loaded
modprobe g_mass_storage || error_exit "Failed to load g_mass_storage module."

# Configure mtools if not already set
echo "Configuring mtools..."
if ! grep -Fxq 'drive p: file="/piusb.bin" exclusive' /root/.mtoolsrc; then
    echo 'drive p: file="/piusb.bin" exclusive' >> /root/.mtoolsrc || error_exit "Failed to configure .mtoolsrc."
    echo "mtoolsrc configured successfully."
else
    echo ".mtoolsrc already configured."
fi

# Final message and reboot
echo ""
echo "USB mass storage setup is complete."
echo "The system will reboot now to apply changes."
echo "=========================================================="
echo ""
reboot now
