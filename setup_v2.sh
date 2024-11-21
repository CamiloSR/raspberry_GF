#!/bin/bash

# usbsetup.sh

# Exit immediately if a command exits with a non-zero status
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

# Update package lists
echo "Updating package lists..."
apt update || error_exit "apt update failed."

# Upgrade all packages
echo "Upgrading packages..."
apt full-upgrade -y || error_exit "apt full-upgrade failed."

# Install required packages
echo "Installing mtools, dos2unix, and Python..."
apt install mtools dos2unix python3-pip -y || error_exit "Package installation failed."

# Set USB image label
USB_IMAGE_LABEL="PIUSB"

# Validate USB_IMAGE_LABEL
if [ ${#USB_IMAGE_LABEL} -gt 11 ] || [[ ! "$USB_IMAGE_LABEL" =~ ^[A-Z0-9_]+$ ]]; then
    error_exit "USB_IMAGE_LABEL must be up to 11 uppercase letters, numbers, or underscores."
fi

# Define USB image path and size
USB_IMAGE_FILE="/piusb.bin"
USB_SIZE_MB=256  # 4 GB

echo "USB Image Label: $USB_IMAGE_LABEL"
echo "USB Image Size: ${USB_SIZE_MB}MB"

# Create USB image if it doesn't exist
if [ ! -f "$USB_IMAGE_FILE" ]; then
    echo "Creating USB image..."
    dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count="$USB_SIZE_MB" status=progress || error_exit "Failed to create USB image."

    # Format as FAT32 without partitioning
    echo "Formatting USB image as FAT32..."
    mkdosfs -F 32 -n "$USB_IMAGE_LABEL" "$USB_IMAGE_FILE" || error_exit "Failed to format USB image."

    chmod 666 "$USB_IMAGE_FILE" || error_exit "Failed to set permissions on USB image."
fi

# Configure USB Gadget
GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

# Clean up existing gadget
if [ -d "$GADGET_DIR" ]; then
    echo "Cleaning up existing USB gadget..."
    sudo umount $GADGET_DIR/functions/mass_storage.0/lun.0/file || true
    sudo rmdir $GADGET_DIR/functions/mass_storage.0 || true
    sudo rmdir $GADGET_DIR/configs/c.1 || true
    sudo rmdir $GADGET_DIR/strings/0x409 || true
    sudo rmdir $GADGET_DIR/functions/mass_storage.0 || true
    sudo rmdir $GADGET_DIR/configs || true
    sudo rmdir $GADGET_DIR || true
fi

# Create gadget
echo "Setting up USB gadget..."
mkdir -p $GADGET_DIR
cd $GADGET_DIR

echo "0xabcd" > idVendor
echo "0x1234" > idProduct
echo "0x0200" > bcdUSB
echo "0x0100" > bcdDevice

# Strings
mkdir -p strings/0x409
echo "010203040506" > strings/0x409/serialnumber
echo "General" > strings/0x409/manufacturer
echo "General UDisk USB Device" > strings/0x409/product

# Configuration
mkdir -p configs/c.1/strings/0x409
echo "Config 1: Mass Storage" > configs/c.1/strings/0x409/configuration
mkdir -p configs/c.1

# Mass Storage Function
mkdir -p functions/mass_storage.0
echo "/piusb.bin" > functions/mass_storage.0/lun.0/file
echo 0 > functions/mass_storage.0/lun.0/removable
echo 1 > functions/mass_storage.0/lun.0/nofua

# Link Function
ln -s functions/mass_storage.0 configs/c.1/

# Enable Gadget
UDC=$(ls /sys/class/udc | head -n1)
echo $UDC > UDC

# Configure mtools
echo "Configuring mtools..."
cat << EOF > /etc/mtools.conf
drive p: file="/piusb.bin" exclusive
mtools_skip_check=1
EOF

dos2unix /etc/mtools.conf

echo "USB gadget and mtools setup completed."

# Create systemd service
SERVICE_FILE="/etc/systemd/system/usbsetup.service"
echo "Creating systemd service..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=USB Gadget and mtools Setup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/usb-gadget.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Create usb-gadget.sh
GADGET_SCRIPT="/usr/bin/usb-gadget.sh"
echo "Creating USB gadget script..."
cat << 'EOF' > "$GADGET_SCRIPT"
#!/bin/bash

# USB Gadget Configuration Script
# /usr/bin/usb-gadget.sh

# Variables
VID="0xabcd"
PID="0x1234"
bcdDevice="0x0100"
bcdUSB="0x0200"
MANUFACTURER="General"
PRODUCT="General UDisk USB Device"
SERIALNUMBER="010203040506"
USB_IMAGE="/piusb.bin"

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"

# Clean up existing gadget
if [ -d "$GADGET_DIR" ]; then
    sudo umount $GADGET_DIR/functions/mass_storage.0/lun.0/file || true
    sudo rmdir $GADGET_DIR/functions/mass_storage.0 || true
    sudo rmdir $GADGET_DIR/configs/c.1 || true
    sudo rmdir $GADGET_DIR/strings/0x409 || true
    sudo rmdir $GADGET_DIR/functions/mass_storage.0 || true
    sudo rmdir $GADGET_DIR/configs || true
    sudo rmdir $GADGET_DIR || true
fi

# Create gadget
sudo mkdir -p $GADGET_DIR
cd $GADGET_DIR

echo $VID > idVendor
echo $PID > idProduct
echo $bcdUSB > bcdUSB
echo $bcdDevice > bcdDevice

# Strings
sudo mkdir -p strings/0x409
echo "$SERIALNUMBER" > strings/0x409/serialnumber
echo "$MANUFACTURER" > strings/0x409/manufacturer
echo "$PRODUCT" > strings/0x409/product

# Configuration
sudo mkdir -p configs/c.1/strings/0x409
echo "Config 1: Mass Storage" > configs/c.1/strings/0x409/configuration
sudo mkdir -p configs/c.1

# Mass Storage Function
sudo mkdir -p functions/mass_storage.0
echo "$USB_IMAGE" > functions/mass_storage.0/lun.0/file
echo 0 > functions/mass_storage.0/lun.0/removable
echo 1 > functions/mass_storage.0/lun.0/nofua

# Link Function
sudo ln -s functions/mass_storage.0 configs/c.1/

# Enable Gadget
UDC=$(ls /sys/class/udc | head -n1)
echo $UDC > UDC
EOF

# Convert line endings and make executable
echo "Converting line endings and making USB gadget script executable..."
dos2unix "$GADGET_SCRIPT"
chmod +x "$GADGET_SCRIPT" || error_exit "Failed to make USB gadget script executable."

# Enable and start systemd service
echo "Enabling and starting usbsetup.service..."
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
systemctl enable usbsetup.service || error_exit "Failed to enable usbsetup.service."
systemctl start usbsetup.service || error_exit "Failed to start usbsetup.service."

echo "All operations completed successfully. Rebooting..."
reboot now
