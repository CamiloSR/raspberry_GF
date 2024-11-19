#!/bin/bash

modprobe libcomposite
cd /sys/kernel/config/usb_gadget/
mkdir -p g1
cd g1

echo 0x058f > idVendor    # Replace XXXX with the Vendor ID of the working USB
echo 0x6387 > idProduct   # Replace YYYY with the Product ID of the working USB

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
ls /sys/class/udc > UDC
