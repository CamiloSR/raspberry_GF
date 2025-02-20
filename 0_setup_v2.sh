#!/bin/bash
# ==============================================================================
# setup_usb_mass_storage_with_reboot.sh
# Purpose:
# This script performs system maintenance, configures Raspberry Pi-specific
# settings (such as disabling Wi-Fi power management and USB power output),
# sets up USB mass storage gadget functionality, and schedules automatic
# reboots at 5:50 AM and 8:00 PM via a cron job.
# ==============================================================================
set -e  # Exit immediately if any command fails

# ------------------------------------------------------------------------------
# Function: error_exit
# Description: Prints an error message and exits the script.
# ------------------------------------------------------------------------------
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# ------------------------------------------------------------------------------
# Root Check: Ensure the script is run as root.
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo ""
    echo "_______________________________"
    echo "Please use sudo or run as root."
    echo "==============================="
    echo ""
    exit 1
fi

# ------------------------------------------------------------------------------
# System Update and Package Installation
# Description: Updates package lists, upgrades packages, and installs
# essential utilities (mtools and dos2unix).
# ------------------------------------------------------------------------------
echo "Updating package lists..."
apt update || error_exit "apt update failed."

echo "Upgrading packages..."
apt full-upgrade -y || error_exit "apt full-upgrade failed."

echo "Installing mtools and dos2unix..."
apt install mtools dos2unix -y || error_exit "Package installation failed."

# ------------------------------------------------------------------------------
# Disable Wi-Fi Power Management
# Description: Appends configuration to disable Wi-Fi power management in
# /etc/dhcpcd.conf and restarts the dhcpcd service if available.
# ------------------------------------------------------------------------------
echo "Disabling Wi-Fi power management..."
DHCPCD_CONF="/etc/dhcpcd.conf"
if [ -f "$DHCPCD_CONF" ]; then
    if ! grep -qx "interface wlan0" "$DHCPCD_CONF"; then
        {
            echo ""
            echo "# Disable Wi-Fi power management"
            echo "interface wlan0"
            echo "nohook wpa_supplicant"
        } >> "$DHCPCD_CONF"
        echo "Wi-Fi power management lines appended to $DHCPCD_CONF."
    else
        echo "Wi-Fi power management already configured. Skipping..."
    fi
    if systemctl list-units --type=service | grep -q "dhcpcd.service"; then
         systemctl restart dhcpcd || error_exit "Failed to restart dhcpcd."
         echo "Wi-Fi power management has been disabled."
    else
         echo "dhcpcd service not found, skipping restart."
    fi
else
    echo "File $DHCPCD_CONF not found, skipping Wi-Fi power management configuration."
fi

# ------------------------------------------------------------------------------
# Disable USB Power Output (VC_USB)
# Description: Disables USB power output if the control file is available.
# ------------------------------------------------------------------------------
echo "Disabling USB power output..."
USB_POWER_FILE="/sys/devices/platform/soc/20980000.usb/buspower"
if [ -f "$USB_POWER_FILE" ]; then
    echo '1' | tee "$USB_POWER_FILE" || error_exit "Failed to disable USB power output."
    echo "USB power output disabled."
else
    echo "USB power control file not found, skipping USB power disable."
fi

echo "All operations completed successfully."

# ------------------------------------------------------------------------------
# USB Mass Storage Setup
# Description: Configures the USB mass storage gadget by creating and
# formatting a USB image file, setting up the necessary kernel modules and
# mtools configuration.
# ------------------------------------------------------------------------------
# Set USB image label (up to 11 uppercase characters)
USB_IMAGE_LABEL="PIUSB"
if [ ${#USB_IMAGE_LABEL} -gt 11 ] || [[ ! "$USB_IMAGE_LABEL" =~ ^[A-Z0-9_]+$ ]]; then
    error_exit "USB_IMAGE_LABEL must be up to 11 uppercase letters, numbers, or underscores."
fi

# Define USB image file and size (in MB)
USB_IMAGE_FILE="/piusb.bin"
USB_SIZE_MB=2048  # 2GB

echo "USB Image Label: $USB_IMAGE_LABEL"
echo "USB Image Size: ${USB_SIZE_MB}MB"

# Enable dwc2 overlay for USB gadget functionality
CONFIG_TXT="/boot/firmware/config.txt"
if ! grep -q "^dtoverlay=dwc2,dr_mode=peripheral" "$CONFIG_TXT"; then
    echo "Configuring dwc2 overlay in $CONFIG_TXT..."
    cp "$CONFIG_TXT" "$CONFIG_TXT.bak"
    sed -i '/^[^#]*dtoverlay=dwc2/s/^/#/' "$CONFIG_TXT"
    echo "dtoverlay=dwc2,dr_mode=peripheral" >> "$CONFIG_TXT" || error_exit "Failed to modify $CONFIG_TXT."
fi

# Ensure dwc2 and g_mass_storage modules are loaded at boot
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

# Remove existing USB image if present
if [ -f "$USB_IMAGE_FILE" ]; then
    echo "Removing existing USB image $USB_IMAGE_FILE..."
    modprobe -r g_mass_storage || true
    rm -f "$USB_IMAGE_FILE" || error_exit "Failed to remove existing USB image."
fi

# Create USB image file with specified size
echo "Creating USB image file $USB_IMAGE_FILE..."
dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count="$USB_SIZE_MB" status=progress || error_exit "Failed to create USB image file."

# Format the USB image with FAT32 filesystem
echo "Formatting $USB_IMAGE_FILE with FAT32 filesystem..."
mkdosfs -F 32 -n "$USB_IMAGE_LABEL" "$USB_IMAGE_FILE" || error_exit "Failed to format USB image file."

# Set appropriate permissions for the USB image file
chmod 666 "$USB_IMAGE_FILE" || error_exit "Failed to set permissions on USB image file."

# Load the g_mass_storage module using the USB image
echo "Loading g_mass_storage module with $USB_IMAGE_FILE..."
modprobe -r g_mass_storage || true
modprobe g_mass_storage || error_exit "Failed to load g_mass_storage module."

# Update mtools configuration for USB image access
CONFIG_FILE="/home/pi/.mtoolsrc"
touch "$CONFIG_FILE"
grep -qxF 'drive p: file="/piusb.bin" exclusive' "$CONFIG_FILE" || echo 'drive p: file="/piusb.bin" exclusive' >> "$CONFIG_FILE"
grep -qxF 'mtools_skip_check=1' "$CONFIG_FILE" || echo 'mtools_skip_check=1' >> "$CONFIG_FILE"
echo "mtools configuration updated in $CONFIG_FILE."

# ------------------------------------------------------------------------------
# Schedule Automatic Reboot Cron Job
# Description: Creates a cron job file that schedules automatic reboots
# at 5:50 AM and 8:00 PM local time.
# ------------------------------------------------------------------------------
echo "Scheduling automatic reboots..."
CRON_FILE="/etc/cron.d/auto_reboot"
cat <<EOF > "$CRON_FILE"
# Auto reboot at 5:50 AM and 8:00 PM local time
50 5 * * * root /sbin/shutdown -r now
0 20 * * * root /sbin/shutdown -r now
EOF
chmod 644 "$CRON_FILE"
echo "Automatic reboot cron jobs added in $CRON_FILE."
echo "Verifying cron job:"
cat /etc/cron.d/auto_reboot
ls -l /etc/cron.d/auto_reboot

# ------------------------------------------------------------------------------
# Final Message and Reboot
# Description: Displays a completion message and reboots the system.
# ------------------------------------------------------------------------------
echo ""
echo "USB mass storage setup is complete."
echo "The system will reboot now to apply changes."
echo "=========================================================="
echo ""
reboot now
