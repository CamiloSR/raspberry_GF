#!/bin/bash

USB_IMAGE_FILE="/piusb.bin"
USB_IMAGE_LABEL="PIUSB"
ID_VENDOR="0x058f"
ID_PRODUCT="0x6387"

# Create USB image if it doesn't exist
if [ ! -f "$USB_IMAGE_FILE" ]; then
    dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count=2048
    mkdosfs -F 32 -n "$USB_IMAGE_LABEL" "$USB_IMAGE_FILE"
fi

modprobe libcomposite
cd /sys/kernel/config/usb_gadget/
mkdir -p g1
cd g1

echo $ID_VENDOR > idVendor
echo $ID_PRODUCT > idProduct
echo "0x0100" > bcdDevice
echo "0x0200" > bcdUSB

mkdir -p strings/0x409
echo "6&14FAAF72&0&_&0" > strings/0x409/serialnumber
echo "General" > strings/0x409/manufacturer
echo "UDisk" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "Config 1" > configs/c.1/strings/0x409/configuration
echo 120 > configs/c.1/MaxPower

mkdir -p functions/mass_storage.0
echo 0 > functions/mass_storage.0/stall
echo 1 > functions/mass_storage.0/lun.0/removable
echo "$USB_IMAGE_FILE" > functions/mass_storage.0/lun.0/file

ln -s functions/mass_storage.0 configs/c.1/
UDC=$(ls /sys/class/udc | head -n1)
echo "$UDC" > UDC
