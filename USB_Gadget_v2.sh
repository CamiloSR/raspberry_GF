#!/bin/bash

set -e

# Function to display error messages
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Load necessary modules
modprobe libcomposite || error_exit "Failed to load libcomposite module."

# Ensure configfs is mounted
if ! mountpoint -q /sys/kernel/config; then
    mount -t configfs none /sys/kernel/config || error_exit "Failed to mount configfs."
fi

# Variables
VID="0xabcd"
PID="0x1234"
bcdDevice="0x0100"
bcdUSB="0x0200"
MANUFACTURER="General"
PRODUCT="General UDisk USB Device"
SERIALNUMBER="6&14FAAF72&0&_&0"
USB_IMAGE="/piusb.bin"

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

# Check if USB image exists
if [ ! -f "$USB_IMAGE" ]; then
    error_exit "USB image file $USB_IMAGE does not exist."
fi

# Clean up existing gadget
if [ -d "$GADGET_DIR" ]; then
    echo "Cleaning up existing USB gadget..."
    umount "$GADGET_DIR"/functions/mass_storage.0/lun.0/file 2>/dev/null || true
    rmdir "$GADGET_DIR"/functions/mass_storage.0/lun.0 2>/dev/null || true
    rmdir "$GADGET_DIR"/functions/mass_storage.0 2>/dev/null || true
    rmdir "$GADGET_DIR"/configs/c.1 2>/dev/null || true
    rmdir "$GADGET_DIR"/strings/0x409 2>/dev/null || true
    rmdir "$GADGET_DIR"/configs 2>/dev/null || true
    rmdir "$GADGET_DIR" 2>/dev/null || true
fi

# Create gadget directory
mkdir -p "$GADGET_DIR" || error_exit "Failed to create gadget directory."

cd "$GADGET_DIR" || error_exit "Failed to enter gadget directory."

# Set Vendor and Product ID
echo "$VID" > idVendor || error_exit "Failed to set idVendor."
echo "$PID" > idProduct || error_exit "Failed to set idProduct."

# Set USB and device version
echo "$bcdUSB" > bcdUSB || error_exit "Failed to set bcdUSB."
echo "$bcdDevice" > bcdDevice || error_exit "Failed to set bcdDevice."

# Create English strings
mkdir -p strings/0x409 || error_exit "Failed to create strings directory."
echo "$SERIALNUMBER" > strings/0x409/serialnumber || error_exit "Failed to set serialnumber."
echo "$MANUFACTURER" > strings/0x409/manufacturer || error_exit "Failed to set manufacturer."
echo "$PRODUCT" > strings/0x409/product || error_exit "Failed to set product."

# Create configuration
mkdir -p configs/c.1/strings/0x409 || error_exit "Failed to create config strings."
echo "Config 1: Mass Storage" > configs/c.1/strings/0x409/configuration || error_exit "Failed to set configuration string."
mkdir -p configs/c.1 || error_exit "Failed to create config directory."

# Add mass storage function
mkdir -p functions/mass_storage.0/lun.0 || error_exit "Failed to create lun.0 directory."
echo "$USB_IMAGE" > functions/mass_storage.0/lun.0/file || error_exit "Failed to set USB image file."
echo 1 > functions/mass_storage.0/lun.0/removable || error_exit "Failed to set removable."
echo 1 > functions/mass_storage.0/lun.0/nofua || error_exit "Failed to set nofua."

# Link function to config
ln -sf functions/mass_storage.0 configs/c.1/ || error_exit "Failed to link mass_storage to config."

# Enable the gadget
UDC=$(ls /sys/class/udc | head -n1)
if [ -n "$UDC" ]; then
    echo "$UDC" > UDC || error_exit "Failed to bind UDC."
else
    error_exit "No UDC found."
fi

echo "USB Gadget configured successfully."
