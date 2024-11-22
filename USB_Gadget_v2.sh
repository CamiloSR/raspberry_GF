#!/bin/bash

# USB Gadget Configuration Script

set -e

modprobe -r g_mass_storage || true
modprobe libcomposite

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

# Clean up existing gadget
if [ -d "\$GADGET_DIR" ]; then
    umount "\$GADGET_DIR"/functions/mass_storage.0/lun.0/file 2>/dev/null || true
    rmdir "\$GADGET_DIR"/functions/mass_storage.0 2>/dev/null || true
    rmdir "\$GADGET_DIR"/configs/c.1 2>/dev/null || true
    rmdir "\$GADGET_DIR"/strings/0x409 2>/dev/null || true
    rmdir "\$GADGET_DIR"/configs 2>/dev/null || true
    rmdir "\$GADGET_DIR" 2>/dev/null || true
fi

# Create gadget directory
mkdir -p "\$GADGET_DIR"
cd "\$GADGET_DIR"

# Set Vendor and Product ID
echo "\$VID" > idVendor
echo "\$PID" > idProduct

# Set USB and device version
echo "\$bcdUSB" > bcdUSB
echo "\$bcdDevice" > bcdDevice

# Create English strings
mkdir -p strings/0x409
echo "\$SERIALNUMBER" > strings/0x409/serialnumber
echo "\$MANUFACTURER" > strings/0x409/manufacturer
echo "\$PRODUCT" > strings/0x409/product

# Create configuration
mkdir -p configs/c.1/strings/0x409
echo "Config 1: Mass Storage" > configs/c.1/strings/0x409/configuration
mkdir -p configs/c.1

# Add mass storage function
mkdir -p functions/mass_storage.0
echo "\$USB_IMAGE" > functions/mass_storage.0/lun.0/file
echo 1 > functions/mass_storage.0/lun.0/removable
echo 1 > functions/mass_storage.0/lun.0/nofua

# Link function to config
ln -sf functions/mass_storage.0 configs/c.1/ || true

# Enable the gadget
UDC=\$(ls /sys/class/udc | head -n1)
if [ -n "\$UDC" ]; then
    echo "\$UDC" > UDC
else
    echo "No UDC found" >&2
    exit 1
fi
