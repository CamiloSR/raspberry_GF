#!/bin/bash
# ==============================================================================
# V4.0.0
# IMPORTANT: THIS SCRIPT IS INTENDED FOR RAPSBERRY PI ZERO 2 W RUNNING 32BIT LITE VERSION
# Purpose:
# This script automates system maintenance, configures Raspberry Pi-specific
# settings (boot behavior and filesystem expansion), installs essential packages
# (including python3-pip), sets up USB mass storage gadget functionality,
# creates an empty LOGGER.GAM file on the USB storage if missing (with initial header and sample data),
# installs a log rotation script for memory management of LOGGER.GAM (trims to header + last 4 lines on boot and before scheduled reboots,
# appending the rest to LOGS_BKP.GAM), schedules automatic reboots at 5:50 AM and 8:00 PM (with rotation before reboot),
# and ensures all changes are applied via reboot.
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
# Configure Timezone:
# Description: Set the timezone to a default value. Change as needed.
# ------------------------------------------------------------------------------
echo "Configuring timezone..."
TIMEZONE="America/New_York"  # Change this to your desired timezone
timedatectl set-timezone "$TIMEZONE" || error_exit "Failed to set timezone."
echo "Timezone set to $TIMEZONE."

# ------------------------------------------------------------------------------
# Configure Raspberry Pi-specific Settings:
# Description: Set boot behavior to console autologin and expand the filesystem.
# Note: Running these steps first ensures that the system is configured
# properly before installing any additional packages.
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
# Description: Disable Wi-Fi power saving for wlan0 safely.
# Notes:
# - DO NOT add 'nohook wpa_supplicant' to dhcpcd.conf (can break Wi-Fi).
# - We also remove any previous (incorrect) block that may have been appended.
# - We apply 'iw' power_save off (non-persistent by itself, but safe).
# ------------------------------------------------------------------------------
echo "Disabling Wi-Fi power management..."
DHCPCD_CONF="/etc/dhcpcd.conf"
if [ -f "$DHCPCD_CONF" ]; then
    # Safe cleanup: remove any previously appended incorrect block, if present
    sed -i '/# Disable Wi-Fi power management/,+2d' "$DHCPCD_CONF" || true
fi

# Disable power saving immediately (best-effort; may fail if interface not up yet)
iw dev wlan0 set power_save off || true

# Show whether NetworkManager is active (helps decide persistent method later)
if systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager detected (NM)."
else
    echo "NetworkManager not active (NOT_NM)."
fi

# ------------------------------------------------------------------------------
# Disable USB Power Output:
# Description: Disables USB power output for device-specific needs.
# ------------------------------------------------------------------------------
echo "Disabling USB power output..."
USB_POWER_FILE="/sys/devices/platform/soc/20980000.usb/buspower"
if [ -f "$USB_POWER_FILE" ]; then
    echo '0' | tee "$USB_POWER_FILE" || error_exit "Failed to disable USB power output."
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
# Update mtools Configuration:
# Description: Configure mtools system-wide in /etc/mtools.conf for both root and users.
# ------------------------------------------------------------------------------
MTOOLS_CONF="/etc/mtools.conf"
echo "Configuring mtools in $MTOOLS_CONF..."
if ! grep -q "drive p: file=\"$USB_IMAGE_FILE\"" "$MTOOLS_CONF" 2>/dev/null; then
    {
        echo ""
        echo "# USB Mass Storage Configuration"
        echo "drive p: file=\"$USB_IMAGE_FILE\" exclusive"
        echo "mtools_skip_check=1"
    } >> "$MTOOLS_CONF"
    echo "mtools configuration added to $MTOOLS_CONF."
else
    echo "mtools configuration already exists in $MTOOLS_CONF."
fi

# Also create user-specific config for pi user for convenience
PI_MTOOLS="/home/pi/.mtoolsrc"
echo "Creating mtools config for pi user..."
cat > "$PI_MTOOLS" <<EOF
drive p: file="$USB_IMAGE_FILE" exclusive
mtools_skip_check=1
EOF
chown pi:pi "$PI_MTOOLS" || error_exit "Failed to set ownership on $PI_MTOOLS."
chmod 644 "$PI_MTOOLS"
echo "User-specific mtools configuration created at $PI_MTOOLS."

# ------------------------------------------------------------------------------
# Create LOGGER.GAM if Missing:
# Description: Create an initial LOGGER.GAM file on the USB storage with header and sample data if it does not exist.
# NOTE: We include 4 sample data lines so the file starts at 5 total lines (header + 4),
# matching the rotation design ("keep header + last 4 lines").
# ------------------------------------------------------------------------------
echo "Checking for LOGGER.GAM on USB storage..."
if ! mdir -i "$USB_IMAGE_FILE" :: | grep -qi 'LOGGER[[:space:]]\+GAM'; then
    echo "Creating LOGGER.GAM file on USB storage..."
    cat <<EOF > /tmp/LOGGER.GAM
GAMA LOG TYPE: G-250 H D;VERSION: 090617;METRIC: N
03-02-2025 12:54:56;91597;82;80;90;88;81;69;500;1;0;0;620;770;940;0
03-02-2025 12:54:58;91597;82;80;90;88;81;69;500;1;0;0;630;790;940;0
03-02-2025 12:55:00;91597;82;80;89;88;81;69;500;1;0;0;620;790;941;0
03-02-2025 12:55:02;91597;82;80;89;88;81;69;500;1;0;0;625;795;942;0
EOF
    mcopy -i "$USB_IMAGE_FILE" /tmp/LOGGER.GAM ::LOGGER.GAM || error_exit "Failed to create LOGGER.GAM file"
    rm /tmp/LOGGER.GAM
    echo "LOGGER.GAM created successfully."
else
    echo "LOGGER.GAM already exists. Skipping creation."
fi

# ------------------------------------------------------------------------------
# Install Log Rotation Script for Memory Management:
# Description: Install a script to rotate LOGGER.GAM (keep header + last 4 lines, append rest to LOGS_BKP.GAM).
# Includes lockfile mechanism to prevent rotation during active operations.
# ------------------------------------------------------------------------------
echo "Installing log rotation script..."
cat >/usr/local/sbin/rotate_logger.sh <<'ROTATE_EOF'
#!/usr/bin/env bash
set -euo pipefail

IMG="/piusb.bin"
LOCKFILE="/var/lock/rotate_logger.lock"
LOGFILE="/var/log/rotate_logger.log"

# Function to log messages
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# Acquire lock to prevent concurrent rotations
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log_msg "Another rotation is in progress. Exiting."
    exit 0
fi

log_msg "Starting log rotation..."

# Try to copy LOGGER.GAM; if missing, exit
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if ! mcopy -n -i "$IMG" ::LOGGER.GAM "$tmp/LOGGER.GAM" 2>/dev/null; then
    log_msg "LOGGER.GAM not found on image. Nothing to rotate."
    exit 0
fi

lines=$(wc -l < "$tmp/LOGGER.GAM")
log_msg "LOGGER.GAM has $lines lines."

if (( lines <= 5 )); then
    log_msg "LOGGER.GAM has <=5 lines; nothing to rotate."
    exit 0
fi

# Extract header, tail, and body
head -n 1 "$tmp/LOGGER.GAM" >"$tmp/header"
tail -n 4 "$tmp/LOGGER.GAM" >"$tmp/tail"
sed -n '2,$p' "$tmp/LOGGER.GAM" | head -n $((lines-5)) >"$tmp/body" || true

# Pull existing backup (if any)
if mcopy -n -i "$IMG" ::LOGS_BKP.GAM "$tmp/LOGS_BKP.GAM" 2>/dev/null; then
    log_msg "Found existing LOGS_BKP.GAM."
else
    log_msg "No existing LOGS_BKP.GAM found. Creating new one."
    : >"$tmp/LOGS_BKP.GAM"
fi

# Append body to backup and write back
if [ -s "$tmp/body" ]; then
    body_lines=$(wc -l < "$tmp/body")
    log_msg "Appending $body_lines lines to LOGS_BKP.GAM."
    cat "$tmp/body" >>"$tmp/LOGS_BKP.GAM"
    mcopy -o -i "$IMG" "$tmp/LOGS_BKP.GAM" ::LOGS_BKP.GAM || {
        log_msg "ERROR: Failed to write LOGS_BKP.GAM"
        exit 1
    }
fi

# Rebuild LOGGER.GAM (header + last 4 lines)
cat "$tmp/header" "$tmp/tail" >"$tmp/LOGGER.NEW"
mcopy -o -i "$IMG" "$tmp/LOGGER.NEW" ::LOGGER.GAM || {
    log_msg "ERROR: Failed to write new LOGGER.GAM"
    exit 1
}

log_msg "Rotation complete. LOGGER.GAM now has 5 lines (header + 4 data lines)."
ROTATE_EOF
chmod +x /usr/local/sbin/rotate_logger.sh
echo "Log rotation script installed at /usr/local/sbin/rotate_logger.sh"

# ------------------------------------------------------------------------------
# Install Systemd Service for Log Rotation on Boot:
# Description: Create and enable a systemd service to run the rotation script on every boot.
# ------------------------------------------------------------------------------
echo "Installing systemd service for log rotation..."
cat >/etc/systemd/system/rotate-logger.service <<'UNIT_EOF'
[Unit]
Description=Rotate LOGGER.GAM on boot
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rotate_logger.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
systemctl enable rotate-logger.service || error_exit "Failed to enable rotate-logger.service."
echo "Systemd service rotate-logger.service enabled."

# ------------------------------------------------------------------------------
# Schedule Automatic Reboots:
# Description: Add cron jobs to rotate logs and reboot the system at 5:50 AM and 8:00 PM local time.
# Using semicolon instead of && to ensure reboot happens even if rotation fails.
# ------------------------------------------------------------------------------
CRON_FILE="/etc/cron.d/auto_reboot"
echo "Scheduling automatic reboots with log rotation..."
cat <<EOF > "$CRON_FILE"
# Auto reboot at 5:50 AM and 8:00 PM local time (timezone: $TIMEZONE)
# Rotation runs first, then system reboots regardless of rotation success
50 5 * * * root /usr/local/sbin/rotate_logger.sh; /sbin/shutdown -r now
0 20 * * * root /usr/local/sbin/rotate_logger.sh; /sbin/shutdown -r now
EOF
chmod 644 "$CRON_FILE"
echo "Automatic reboot cron jobs added in $CRON_FILE."

# ------------------------------------------------------------------------------
# Note about g_mass_storage Module:
# Description: The module will be loaded automatically on reboot with the configured parameters.
# We don't load it now to avoid conflicts before reboot.
# ------------------------------------------------------------------------------
echo ""
echo "Note: The g_mass_storage module will be loaded automatically on reboot."
echo "Module parameters have been configured in $G_MASS_STORAGE_CONF."

# ------------------------------------------------------------------------------
# Final Message and Reboot:
# Description: Notify the user of completion and reboot the system.
# ------------------------------------------------------------------------------
echo ""
echo "========================================================================"
echo "Setup Complete!"
echo "========================================================================"
echo "Changes made:"
echo "  - Timezone set to: $TIMEZONE"
echo "  - USB mass storage configured with $USB_IMAGE_FILE"
echo "  - LOGGER.GAM initialized on USB storage"
echo "  - Log rotation script installed with lockfile protection"
echo "  - Automatic log rotation on boot enabled"
echo "  - Scheduled reboots at 5:50 AM and 8:00 PM with log rotation"
echo "  - mtools configured system-wide in /etc/mtools.conf"
echo ""
echo "The system will reboot now to apply all changes."
echo "========================================================================"
echo ""
sleep 3
reboot now
