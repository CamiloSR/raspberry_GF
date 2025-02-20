#!/bin/bash
# ==============================================================================
# 0_setup_v3.sh
# Purpose:
# This script automates system maintenance, configures Raspberry Pi-specific
# settings (boot behavior and filesystem expansion), installs essential packages
# (including python3-pip), sets up USB mass storage gadget functionality,
# schedules automatic reboots at 5:50 AM and 8:00 PM, and creates an empty
# LOGGER.GAM file on the USB storage if missing.
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
# Configure Raspberry Pi-specific Settings:
# Description: Set boot behavior to console autologin and expand the filesystem.
# Note: Running these steps first ensures that the system is configured
#       properly before installing any additional packages.
# ------------------------------------------------------------------------------
echo "Configuring Raspberry Pi-specific options..."
raspi-config nonint do_boot_behaviour B2 || error_exit "Failed to set boot behavior."
raspi-config nonint do_expand_rootfs || error_exit "Failed to expand filesystem."

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
# Install python3-pip:
# Description: Install the python3-pip package.
# ------------------------------------------------------------------------------
echo "Installing python3-pip..."
apt install python3-pip -y || error_exit "Failed to install python3-pip."

# ------------------------------------------------------------------------------
# Disable Wi-Fi Power Management:
# Description: Append configuration to disable Wi-Fi power management for wlan0.
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
# Disable USB Power Output:
# Description: Disables USB power output for device-specific needs.
# ------------------------------------------------------------------------------
echo "Disabling USB power output..."
USB_POWER_FILE="/sys/devices/platform/soc/20980000.usb/buspower"
if [ -f "$USB_POWER_FILE" ]; then
    echo '1' | tee "$USB_POWER_FILE" || error_exit "Failed to disable USB power output."
    echo "USB power output disabled."
else
    echo "USB power control file not found, skipping USB power disable."
fi

echo "All preliminary operations completed successfully."

# ------------------------------------------------------------------------------
# USB MASS STORAGE SETUP:
# Description: Create and configure a USB image file for mass storage.
# ------------------------------------------------------------------------------
# Define the USB image label (max 11 uppercase letters/numbers/underscores)
USB_IMAGE_LABEL="PIUSB"
if [ ${#USB_IMAGE_LABEL} -gt 11 ] || [[ ! "$USB_IMAGE_LABEL" =~ ^[A-Z0-9_]+$ ]]; then
    error_exit "USB_IMAGE_LABEL must be up to 11 uppercase letters, numbers, or underscores."
fi

# Define the path and size of the USB image file
USB_IMAGE_FILE="/piusb.bin"
USB_SIZE_MB=2048  # 2GB
echo "USB Image Label: $USB_IMAGE_LABEL"
echo "USB Image Size: ${USB_SIZE_MB}MB"

# ------------------------------------------------------------------------------
# Configure dwc2 Overlay:
# Description: Enable the dwc2 overlay in the config file for USB gadget mode.
# ------------------------------------------------------------------------------
CONFIG_TXT="/boot/firmware/config.txt"
if ! grep -q "^dtoverlay=dwc2,dr_mode=peripheral" "$CONFIG_TXT"; then
    echo "Configuring dwc2 overlay in $CONFIG_TXT..."
    cp "$CONFIG_TXT" "$CONFIG_TXT.bak"
    sed -i '/^[^#]*dtoverlay=dwc2/s/^/#/' "$CONFIG_TXT"
    echo "dtoverlay=dwc2,dr_mode=peripheral" >> "$CONFIG_TXT" || error_exit "Failed to modify $CONFIG_TXT."
fi

# ------------------------------------------------------------------------------
# Update Kernel Modules:
# Description: Ensure that dwc2 and g_mass_storage modules are loaded at boot.
# ------------------------------------------------------------------------------
MODULES_FILE="/etc/modules"
for module in dwc2 g_mass_storage; do
    if ! grep -q "^$module$" "$MODULES_FILE"; then
        echo "Adding $module to $MODULES_FILE..."
        echo "$module" >> "$MODULES_FILE" || error_exit "Failed to add $module to $MODULES_FILE."
    else
        echo "$module is already present in $MODULES_FILE."
    fi
done

# ------------------------------------------------------------------------------
# Configure g_mass_storage Module:
# Description: Set module parameters for g_mass_storage using the USB image.
# ------------------------------------------------------------------------------
G_MASS_STORAGE_CONF="/etc/modprobe.d/g_mass_storage.conf"
echo "Configuring g_mass_storage module parameters..."
echo "options g_mass_storage file=$USB_IMAGE_FILE removable=1 ro=0 stall=0" > "$G_MASS_STORAGE_CONF" || error_exit "Failed to create $G_MASS_STORAGE_CONF."

# ------------------------------------------------------------------------------
# Reload System Configurations:
# Description: Reload systemd daemon and update module dependencies.
# ------------------------------------------------------------------------------
echo "Reloading configurations..."
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
depmod -a || error_exit "Failed to reload modprobe configurations."

# ------------------------------------------------------------------------------
# Remove Existing USB Image:
# Description: If a previous USB image exists, remove it before creating a new one.
# ------------------------------------------------------------------------------
if [ -f "$USB_IMAGE_FILE" ]; then
    echo "Removing existing USB image $USB_IMAGE_FILE..."
    modprobe -r g_mass_storage || true  # Remove g_mass_storage if loaded
    rm -f "$USB_IMAGE_FILE" || error_exit "Failed to remove existing USB image."
fi

# ------------------------------------------------------------------------------
# Create USB Image:
# Description: Create a blank USB image file with the defined size.
# ------------------------------------------------------------------------------
echo "Creating USB image file $USB_IMAGE_FILE..."
dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count="$USB_SIZE_MB" status=progress || error_exit "Failed to create USB image file."

# ------------------------------------------------------------------------------
# Format USB Image:
# Description: Format the USB image with a FAT32 filesystem and set a label.
# ------------------------------------------------------------------------------
echo "Formatting $USB_IMAGE_FILE with FAT32 filesystem..."
mkdosfs -F 32 -n "$USB_IMAGE_LABEL" "$USB_IMAGE_FILE" || error_exit "Failed to format USB image file."

# ------------------------------------------------------------------------------
# Set USB Image Permissions:
# Description: Update permissions to allow read/write access.
# ------------------------------------------------------------------------------
chmod 666 "$USB_IMAGE_FILE" || error_exit "Failed to set permissions on USB image file."

# ------------------------------------------------------------------------------
# Load g_mass_storage Module:
# Description: Load the g_mass_storage module with the created USB image.
# ------------------------------------------------------------------------------
echo "Loading g_mass_storage module with $USB_IMAGE_FILE..."
modprobe -r g_mass_storage || true
modprobe g_mass_storage || error_exit "Failed to load g_mass_storage module."

# ------------------------------------------------------------------------------
# Update mtools Configuration:
# Description: Configure mtools to recognize the USB image for mass storage.
# ------------------------------------------------------------------------------
CONFIG_FILE="/home/pi/.mtoolsrc"
touch "$CONFIG_FILE"
grep -qxF 'drive p: file="/piusb.bin" exclusive' "$CONFIG_FILE" || echo 'drive p: file="/piusb.bin" exclusive' >> "$CONFIG_FILE"
grep -qxF 'mtools_skip_check=1' "$CONFIG_FILE" || echo 'mtools_skip_check=1' >> "$CONFIG_FILE"
echo "mtools configuration updated in $CONFIG_FILE."

# ------------------------------------------------------------------------------
# Schedule Automatic Reboots:
# Description: Add cron jobs to reboot the system at 5:50 AM and 8:00 PM local time.
# ------------------------------------------------------------------------------
CRON_FILE="/etc/cron.d/auto_reboot"
echo "Scheduling automatic reboots..."
cat <<EOF > "$CRON_FILE"
# Auto reboot at 5:50 AM and 8:00 PM local time
50 5 * * * root /sbin/shutdown -r now
0 20 * * * root /sbin/shutdown -r now
EOF
chmod 644 "$CRON_FILE"
echo "Automatic reboot cron jobs added in $CRON_FILE."

# ------------------------------------------------------------------------------
# Final Message and Reboot:
# Description: Notify the user of completion and reboot the system.
# ------------------------------------------------------------------------------
echo ""
echo "USB mass storage setup and scheduling complete."
echo "The system will reboot now to apply changes."
echo "=========================================================="
echo ""
reboot now
