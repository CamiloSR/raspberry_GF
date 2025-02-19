#!/bin/bash
# ==============================================================================
# Purpose:
# This script must be run in ROOT mode (e.g., via "sudo su"). It performs
# initial USB gadget reset operations (disabling and unbinding g_mass_storage),
# configures Raspberry Pi-specific settings (boot behavior and filesystem expansion),
# and then proceeds to update the system, install packages, set up USB mass storage
# functionality, schedule automatic reboots, and create an empty LOGGER.GAM file if missing.
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
    echo "This script must be run as root. Use 'sudo su' to switch to root."
    exit 1
fi

# ------------------------------------------------------------------------------
# Configure Raspberry Pi-specific Settings:
# Description: Set boot behavior to console autologin and expand the filesystem.
# Note: Running these steps first ensures that the system is configured properly
#       before performing any further operations.
# ------------------------------------------------------------------------------
echo "Configuring Raspberry Pi-specific options..."
raspi-config nonint do_boot_behaviour B2 || error_exit "Failed to set boot behavior."
raspi-config nonint do_expand_rootfs || error_exit "Failed to expand filesystem."

# ------------------------------------------------------------------------------
# USB Gadget Reset and Disable g_mass_storage:
# Description: Stop using g_mass_storage by unbinding the USB gadget,
#              removing the module, preventing it from loading at boot by
#              commenting it out in /etc/modules, and removing its modprobe config.
#              These operations must occur in root mode.
# ------------------------------------------------------------------------------
echo "Resetting USB gadget configuration and disabling g_mass_storage..."

# Unbind USB gadget by writing an empty string to UDC
if [ -e /sys/kernel/config/usb_gadget/g1/UDC ]; then
    echo "" > /sys/kernel/config/usb_gadget/g1/UDC
    echo "USB gadget unbound from UDC."
else
    echo "USB gadget UDC not found, skipping unbind."
fi

# Remove g_mass_storage module if it is loaded
if lsmod | grep -q g_mass_storage; then
    modprobe -r g_mass_storage || echo "Failed to remove g_mass_storage module."
    echo "g_mass_storage module removed."
else
    echo "g_mass_storage module not loaded, skipping removal."
fi

# Prevent g_mass_storage from loading at boot by commenting it out in /etc/modules
if [ -f /etc/modules ]; then
    sed -i 's/^\(g_mass_storage\)/#\1/' /etc/modules
    echo "g_mass_storage commented out in /etc/modules."
else
    echo "/etc/modules not found, skipping modification."
fi

# Remove the modprobe configuration for g_mass_storage
if [ -f /etc/modprobe.d/g_mass_storage.conf ]; then
    rm -f /etc/modprobe.d/g_mass_storage.conf || echo "Failed to remove /etc/modprobe.d/g_mass_storage.conf."
    echo "Removed /etc/modprobe.d/g_mass_storage.conf."
else
    echo "/etc/modprobe.d/g_mass_storage.conf not found, skipping removal."
fi

# ------------------------------------------------------------------------------
# System Update and Upgrade:
# Description: Update package lists and upgrade all installed packages.
# ------------------------------------------------------------------------------
echo "Updating package lists..."
apt update || error_exit "apt update failed."

echo "Upgrading packages..."
apt full-upgrade -y || error_exit "apt full-upgrade failed."

# ------------------------------------------------------------------------------
# Install python3-pip:
# Description: Install the python3-pip package.
# ------------------------------------------------------------------------------
echo "Installing python3-pip..."
apt install python3-pip -y || error_exit "Failed to install python3-pip."

# ------------------------------------------------------------------------------
# Install Additional Packages:
# Description: Install mtools and dos2unix for USB mass storage and file conversion.
# ------------------------------------------------------------------------------
echo "Installing mtools and dos2unix..."
apt install mtools dos2unix -y || error_exit "Package installation failed."

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
USB_IMAGE_LABEL="PIUSB"
if [ ${#USB_IMAGE_LABEL} -gt 11 ] || [[ ! "$USB_IMAGE_LABEL" =~ ^[A-Z0-9_]+$ ]]; then
    error_exit "USB_IMAGE_LABEL must be up to 11 uppercase letters, numbers, or underscores."
fi

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
# Create LOGGER.GAM File:
# Description: Check if LOGGER.GAM exists on the USB storage; if not, create it.
# ------------------------------------------------------------------------------
if ! mdir p:/ | grep -qi "LOGGER.GAM"; then
    echo "Creating empty LOGGER.GAM file on USB storage..."
    touch /tmp/LOGGER.GAM
    mcopy /tmp/LOGGER.GAM p:/LOGGER.GAM || error_exit "Failed to create LOGGER.GAM file"
    rm /tmp/LOGGER.GAM
fi

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
