#!/bin/bash

# Comprehensive USB Gadget Setup Script
# This script configures the Raspberry Pi Zero 2 W as a USB mass storage device
# matching the properties of a working USB device, named PIUSB.
# It integrates creating the USB image, formatting, configuring mtools, and setting up the USB gadget.

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

# Update and upgrade packages
echo "Updating and upgrading packages..."
apt update && apt full-upgrade -y || error_exit "Package update/upgrade failed."

# Install necessary packages
echo "Installing required packages..."
apt install -y mtools dos2unix python3-pip configfs || error_exit "Package installation failed."

# Set USB image parameters
USB_IMAGE_LABEL="PIUSB"
USB_IMAGE_FILE="/piusb.bin"
USB_SIZE_MB=2048  # Adjust size as needed

# Validate USB_IMAGE_LABEL
if [ ${#USB_IMAGE_LABEL} -gt 11 ] || [[ ! "$USB_IMAGE_LABEL" =~ ^[A-Z0-9_]+$ ]]; then
    error_exit "USB_IMAGE_LABEL must be up to 11 uppercase letters, numbers, or underscores."
fi

echo "USB Image Label: $USB_IMAGE_LABEL"
echo "USB Image Size: ${USB_SIZE_MB}MB"

# Create and format USB image
if [ -f "$USB_IMAGE_FILE" ]; then
    echo "Removing existing USB image..."
    rm -f "$USB_IMAGE_FILE" || error_exit "Failed to remove existing USB image."
fi

echo "Creating USB image file..."
dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count="$USB_SIZE_MB" status=progress || error_exit "Failed to create USB image file."

echo "Partitioning USB image..."
(
echo o   # Create a new empty DOS partition table
echo n   # Add a new partition
echo p   # Primary partition
echo 1   # Partition number 1
echo     # First sector (default)
echo     # Last sector (default)
echo w   # Write changes
) | fdisk "$USB_IMAGE_FILE" || error_exit "Failed to partition USB image."

echo "Setting up loop device..."
LOOP_DEVICE=$(losetup -fP "$USB_IMAGE_FILE") || error_exit "Failed to setup loop device."

echo "Formatting USB image with FAT32..."
mkfs.vfat -F 32 -n "$USB_IMAGE_LABEL" "${LOOP_DEVICE}p1" || error_exit "Failed to format USB image."

echo "Detaching loop device..."
losetup -d "$LOOP_DEVICE" || error_exit "Failed to detach loop device."

# Configure mtools
echo "Configuring mtools..."
echo "drive p: file=\"$USB_IMAGE_FILE\" exclusive" > /root/.mtoolsrc
echo "mtools_skip_check=1" >> /root/.mtoolsrc

# Remove g_mass_storage if loaded
echo "Removing g_mass_storage module if loaded..."
modprobe -r g_mass_storage || true

# Ensure configfs is mounted
if ! mountpoint -q /sys/kernel/config; then
    echo "Mounting configfs..."
    mount -t configfs none /sys/kernel/config || error_exit "Failed to mount configfs."
fi

# Setup USB Gadget using libcomposite
GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

echo "Setting up USB Gadget with libcomposite..."

# Clean up any existing gadget
if [ -d "$GADGET_DIR" ]; then
    echo "Cleaning up existing gadget..."
    umount "$GADGET_DIR"/functions/mass_storage.0/lun.0/file || true
    rm -rf "$GADGET_DIR" || true
fi

# Create gadget directory
mkdir -p "$GADGET_DIR"

# USB Descriptors - Replace with actual values
VID="058f"                        # Replace with Vendor ID from working USB (without 0x)
PID="6387"                        # Replace with Product ID from working USB (without 0x)
bcdDevice="0x0100"                # Device version (1.00)
bcdUSB="0x0200"                   # USB version (2.0)
MANUFACTURER="General"            # Manufacturer string
PRODUCT="General UDisk USB Device" # Product string
SERIALNUMBER="010203040506"       # Serial number from working USB

# Set Vendor and Product ID
echo "0x$VID" > "$GADGET_DIR/idVendor"
echo "0x$PID" > "$GADGET_DIR/idProduct"

# Set USB and device version
echo "$bcdUSB" > "$GADGET_DIR/bcdUSB"
echo "$bcdDevice" > "$GADGET_DIR/bcdDevice"

# Create English strings
mkdir -p "$GADGET_DIR/strings/0x409"
echo "$SERIALNUMBER" > "$GADGET_DIR/strings/0x409/serialnumber"
echo "$MANUFACTURER" > "$GADGET_DIR/strings/0x409/manufacturer"
echo "$PRODUCT" > "$GADGET_DIR/strings/0x409/product"

# Create configuration
mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409"
echo "Config 1: Mass Storage" > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
mkdir -p "$GADGET_DIR/configs/c.1"

# Add mass storage function
mkdir -p "$GADGET_DIR/functions/mass_storage.0"
echo "$USB_IMAGE_FILE" > "$GADGET_DIR/functions/mass_storage.0/lun.0/file"
echo 0 > "$GADGET_DIR/functions/mass_storage.0/lun.0/removable"
echo 1 > "$GADGET_DIR/functions/mass_storage.0/lun.0/nofua"

# Link function to config
ln -s "$GADGET_DIR/functions/mass_storage.0" "$GADGET_DIR/configs/c.1/" || error_exit "Failed to link mass_storage.0 to config."

# Enable the gadget
UDC=$(ls /sys/class/udc | head -n1) || error_exit "No UDC found."
echo "$UDC" > "$GADGET_DIR/UDC" || error_exit "Failed to enable gadget."

# Automate gadget setup on boot by creating a systemd service
echo "Creating systemd service to setup USB gadget on boot..."
SERVICE_FILE="/etc/systemd/system/usb-gadget.service"

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=USB Gadget Setup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/usb-gadget.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# Create the usb-gadget.sh script
echo "Creating /usr/bin/usb-gadget.sh script..."
cat <<'EOF' > /usr/bin/usb-gadget.sh
#!/bin/bash

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

# Variables (Replace with actual values if needed)
VID="058f"                           # Vendor ID from working USB (without 0x)
PID="6387"                           # Product ID from working USB (without 0x)
bcdDevice="0x0100"                   # Device version (1.00)
bcdUSB="0x0200"                      # USB version (2.0)
MANUFACTURER="General"               # Manufacturer string
PRODUCT="General UDisk USB Device"    # Product string
SERIALNUMBER="010203040506"          # Serial number from working USB
USB_IMAGE="/piusb.bin"               # Path to your USB image

# Ensure configfs is mounted
if ! mountpoint -q /sys/kernel/config; then
    mount -t configfs none /sys/kernel/config || exit 1
fi

# Ensure gadget directory exists
if [ ! -d "$GADGET_DIR" ]; then
    mkdir -p "$GADGET_DIR"
fi

# Clean up any existing functions
rm -rf "$GADGET_DIR"/functions/mass_storage.0
rm -rf "$GADGET_DIR"/configs/c.1
rm -rf "$GADGET_DIR"/strings/0x409

# Set Vendor and Product ID
echo "0x$VID" > "$GADGET_DIR/idVendor"
echo "0x$PID" > "$GADGET_DIR/idProduct"

# Set USB and device version
echo "$bcdUSB" > "$GADGET_DIR/bcdUSB"
echo "$bcdDevice" > "$GADGET_DIR/bcdDevice"

# Create English strings
mkdir -p "$GADGET_DIR/strings/0x409"
echo "$SERIALNUMBER" > "$GADGET_DIR/strings/0x409/serialnumber"
echo "$MANUFACTURER" > "$GADGET_DIR/strings/0x409/manufacturer"
echo "$PRODUCT" > "$GADGET_DIR/strings/0x409/product"

# Create configuration
mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409"
echo "Config 1: Mass Storage" > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
mkdir -p "$GADGET_DIR/configs/c.1"

# Add mass storage function
mkdir -p "$GADGET_DIR/functions/mass_storage.0"
echo "$USB_IMAGE" > "$GADGET_DIR/functions/mass_storage.0/lun.0/file"
echo 0 > "$GADGET_DIR/functions/mass_storage.0/lun.0/removable"
echo 1 > "$GADGET_DIR/functions/mass_storage.0/lun.0/nofua"

# Link function to config
ln -s "$GADGET_DIR/functions/mass_storage.0" "$GADGET_DIR/configs/c.1/" || exit 1

# Enable the gadget
UDC=$(ls /sys/class/udc | head -n1)
echo "$UDC" > "$GADGET_DIR/UDC"
EOF

# Make usb-gadget.sh executable
chmod +x /usr/bin/usb-gadget.sh || error_exit "Failed to make usb-gadget.sh executable."

# Reload systemd daemon and enable the service
echo "Enabling USB gadget systemd service..."
systemctl daemon-reload
systemctl enable usb-gadget.service

# Final message and reboot
echo ""
echo "USB mass storage setup is complete."
echo "The system will reboot now to apply changes."
echo "=========================================================="
echo ""
reboot now
