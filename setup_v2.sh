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

# Validate USB_IMAGE_LABEL length and characters
if [ ${#USB_IMAGE_LABEL} -gt 11 ] || [[ ! "$USB_IMAGE_LABEL" =~ ^[A-Z0-9_]+$ ]]; then
    error_exit "USB_IMAGE_LABEL must be up to 11 uppercase letters, numbers, or underscores."
fi

# Define the USB image file path
USB_IMAGE_FILE="/piusb.bin"

# Set the size as appropriate (in megabytes)
USB_SIZE_MB=512  # 4 GB

echo "USB Image Label: $USB_IMAGE_LABEL"
echo "USB Image Size: ${USB_SIZE_MB}MB"

# Enable dwc2 overlay in /boot/firmware/config.txt if not already enabled
CONFIG_TXT="/boot/firmware/config.txt"

if ! grep -q "^dtoverlay=dwc2,dr_mode=peripheral" "$CONFIG_TXT"; then
    echo "Configuring dwc2 overlay in $CONFIG_TXT..."
    cp "$CONFIG_TXT" "$CONFIG_TXT.bak"
    sed -i '/^[^#]*dtoverlay=dwc2/s/^/#/' "$CONFIG_TXT"
    echo "dtoverlay=dwc2,dr_mode=peripheral" >> "$CONFIG_TXT" || error_exit "Failed to modify $CONFIG_TXT."
fi

# Ensure 'dwc2' and 'libcomposite' modules are in /etc/modules
MODULES_FILE="/etc/modules"
for module in dwc2 libcomposite; do
    if ! grep -q "^$module$" "$MODULES_FILE"; then
        echo "Adding $module to $MODULES_FILE..."
        echo "$module" >> "$MODULES_FILE" || error_exit "Failed to add $module to $MODULES_FILE."
    else
        echo "$module is already present in $MODULES_FILE."
    fi
done

# Reload systemd and modprobe configurations
echo "Reloading configurations..."
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
depmod -a || error_exit "Failed to reload modprobe configurations."

# Remove existing USB image if it exists
if [ -f "$USB_IMAGE_FILE" ]; then
    echo "Removing existing USB image $USB_IMAGE_FILE..."
    modprobe -r g_mass_storage || true  # Remove if already loaded
    rm -f "$USB_IMAGE_FILE" || error_exit "Failed to remove existing USB image."
fi

# Create the USB image file with specified size
echo "Creating USB image file $USB_IMAGE_FILE..."
dd if=/dev/zero of="$USB_IMAGE_FILE" bs=1M count="$USB_SIZE_MB" status=progress || error_exit "Failed to create USB image file."

# Partition the USB image with MBR and a single FAT32 partition
echo "Partitioning USB image with MBR and a single FAT32 partition..."
echo -e "o\nn\np\n1\n\n\nw" | fdisk "$USB_IMAGE_FILE" || error_exit "Failed to partition USB image."

# Associate the USB image with a loop device
echo "Associating USB image with a loop device..."
LOOP_DEVICE=$(losetup -f --show -P "$USB_IMAGE_FILE") || error_exit "Failed to associate loop device."

# Format the partition as FAT32
echo "Formatting the USB image partition as FAT32..."
mkfs.vfat -F 32 -n "$USB_IMAGE_LABEL" "${LOOP_DEVICE}p1" || error_exit "Failed to format USB image."

# Detach the loop device
echo "Detaching the loop device..."
losetup -d "$LOOP_DEVICE" || error_exit "Failed to detach loop device."

# Set permissions on the USB image file
echo "Setting permissions on the USB image file..."
chmod 666 "$USB_IMAGE_FILE" || error_exit "Failed to set permissions on USB image file."

# Create the USB gadget script
GADGET_SCRIPT="/usr/bin/usb-gadget.sh"
echo "Creating USB gadget script at $GADGET_SCRIPT..."
cat << 'EOF' > "$GADGET_SCRIPT"
#!/bin/bash

# USB Gadget Configuration Script
# /usr/bin/usb-gadget.sh

# Variables
VID="0xabcd"                           # Vendor ID from working USB
PID="0x1234"                           # Product ID from working USB
bcdDevice="0x0100"                     # Device version (1.00)
bcdUSB="0x0200"                        # USB version (2.0)
MANUFACTURER="General"                 # Manufacturer string
PRODUCT="General UDisk USB Device"     # Product string
SERIALNUMBER="010203040506"            # Serial number from working USB
USB_IMAGE="/piusb.bin"                 # Path to your USB image

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

# Create systemd service for USB gadget
SERVICE_FILE="/etc/systemd/system/usb-gadget.service"
echo "Creating systemd service at $SERVICE_FILE..."
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=USB Gadget Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/usb-gadget.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start the service
echo "Reloading systemd daemon..."
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."

echo "Enabling usb-gadget.service..."
systemctl enable usb-gadget.service || error_exit "Failed to enable usb-gadget.service."

echo "Starting usb-gadget.service..."
systemctl start usb-gadget.service || error_exit "Failed to start usb-gadget.service."

# Configure mtools
echo "Configuring mtools..."
cat << EOF > /etc/mtools.conf
drive p: file="/piusb.bin" exclusive
mtools_skip_check=1
EOF

dos2unix /etc/mtools.conf

echo "All operations completed successfully."
echo "The system will reboot now to apply changes."
reboot now
