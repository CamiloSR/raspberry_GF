#!/bin/bash

# USB Gadget Configuration Script
# /usr/bin/usb-gadget.sh

modprobe -r g_mass_storage
modprobe libcomposite

# Variables (Replace with actual values)
VID="0xabcd"                           # Vendor ID from working USB
PID="0x1234"                           # Product ID from working USB
bcdDevice="0x0100"                     # Device version (1.00)
bcdUSB="0x0200"                        # USB version (2.0)
MANUFACTURER="General"                 # Manufacturer string
PRODUCT="General UDisk USB Device"      # Product string
SERIALNUMBER="010203040506"                       # Serial number from working USB
USB_IMAGE="/piusb.bin"                # Path to your USB image

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

# Clean up any existing gadget
if [ -d "$GADGET_DIR" ]; then
    sudo umount $GADGET_DIR/functions/mass_storage.0/lun.0/file || true
    sudo rmdir $GADGET_DIR/functions/mass_storage.0 || true
    sudo rmdir $GADGET_DIR/configs/c.1 || true
    sudo rmdir $GADGET_DIR/strings/0x409 || true
    sudo rmdir $GADGET_DIR/functions/mass_storage.0 || true
    sudo rmdir $GADGET_DIR/configs || true
    sudo rmdir $GADGET_DIR || true
fi

# Create gadget directory
sudo mkdir -p $GADGET_DIR
cd $GADGET_DIR

# Set Vendor and Product ID
echo $VID > idVendor
echo $PID > idProduct

# Set USB and device version
echo $bcdUSB > bcdUSB
echo $bcdDevice > bcdDevice

# Create English strings
sudo mkdir -p strings/0x409
echo "$SERIALNUMBER" > strings/0x409/serialnumber
echo "$MANUFACTURER" > strings/0x409/manufacturer
echo "$PRODUCT" > strings/0x409/product

# Create configuration
sudo mkdir -p configs/c.1/strings/0x409
echo "Config 1: Mass Storage" > configs/c.1/strings/0x409/configuration
sudo mkdir -p configs/c.1

# Add mass storage function
sudo mkdir -p functions/mass_storage.0
echo "$USB_IMAGE" > functions/mass_storage.0/lun.0/file
echo 0 > functions/mass_storage.0/lun.0/removable
echo 1 > functions/mass_storage.0/lun.0/nofua

# Link function to config
sudo ln -s functions/mass_storage.0 configs/c.1/

# Enable the gadget
UDC=$(ls /sys/class/udc | head -n1)
echo $UDC > UDC
