#!/bin/bash

# Comprehensive USB Gadget Setup Script
# Configures Raspberry Pi Zero 2 W as USB mass storage device named PIUSB

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
apt install -y mtools dos2unix python3-pip || error_exit "Package installation failed."

# Set USB image parameters
USB_IMAGE_LABEL="PIUSB"
USB_IMAGE_FILE="/piusb.bin"
USB_SIZE_MB=512  # Adjust size as needed for testing

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
LOOP_DEVICE=$(losetup --find --show -P "$USB_IMAGE_FILE") || error_exit "Failed to setup loop device."

# Wait for the partition to be available
sleep 1

if [ ! -b "${LOOP_DEVICE}p1" ]; then
    error_exit "Partition device ${LOOP_DEVICE}p1 not found."
fi

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

    # Disable the gadget by unbinding the UDC
    if [ -w "$GADGET_DIR/UDC" ]; then
        echo "" > "$GADGET_DIR/UDC"
    fi

    # Wait until the UDC is unbound
    UDC_BOUND=$(cat "$GADGET_DIR/UDC" 2>/dev/null || echo "")
    while [ -n "$UDC_BOUND" ]; do
        echo "Waiting for UDC to unbind..."
        sleep 1
        UDC_BOUND=$(cat "$GADGET_DIR/UDC" 2>/dev/null || echo "")
    done

    # Remove all functions
    if [ -d "$GADGET_DIR/functions/" ]; then
        FUNCTIONS=$(ls "$GADGET_DIR/functions/")
        for FUNC in $FUNCTIONS; do
            rm -rf "$GADGET_DIR/functions/$FUNC" || echo "Warning: Failed to remove function $FUNC"
        done
    fi

    # Remove all configurations
    if [ -d "$GADGET_DIR/configs/" ]; then
        CONFIGS=$(ls "$GADGET_DIR/configs/")
        for CFG in $CONFIGS; do
            rm -rf "$GADGET_DIR/configs/$CFG" || echo "Warning: Failed to remove config $CFG"
        done
    fi

    # Remove all strings
    if [ -d "$GADGET_DIR/strings/" ]; then
        rm -rf "$GADGET_DIR/strings/"* || echo "Warning: Failed to remove strings"
    fi

    # Finally, remove the gadget directory
    rm -rf "$GADGET_DIR" || error_exit "Failed to remove gadget directory."
fi

# Create gadget directory
mkdir -p "$GADGET_DIR" || error_exit "Failed to create gadget directory."

# USB Descriptors
# Ensure VID and PID do NOT have the '0x' prefix
VID="abcd"                        # Vendor ID from working USB (without 0x)
PID="1234"                        # Product ID from working USB (without 0x)
bcdDevice="0x0100"                # Device version (1.00)
bcdUSB="0x0200"                   # USB version (2.0)
MANUFACTURER="General"            # Manufacturer string
PRODUCT="General UDisk USB Device" # Product string
SERIALNUMBER="010203040506"       # Serial number from working USB
USB_IMAGE="/piusb.bin"            # Path to your USB image

# Set Vendor and Product ID
echo "$VID" > "$GADGET_DIR/idVendor"
echo "$PID" > "$GADGET_DIR/idProduct"

# Set USB and device version
echo "$bcdUSB" > "$GADGET_DIR/bcdUSB"
echo "$bcdDevice" > "$GADGET_DIR/bcdDevice"

# Create English strings
mkdir -p "$GADGET_DIR/strings/0x409" || error_exit "Failed to create strings directory."
echo "$SERIALNUMBER" > "$GADGET_DIR/strings/0x409/serialnumber"
echo "$MANUFACTURER" > "$GADGET_DIR/strings/0x409/manufacturer"
echo "$PRODUCT" > "$GADGET_DIR/strings/0x409/product"

# Create configuration
mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409" || error_exit "Failed to create config strings directory."
echo "Config 1: Mass Storage" > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
mkdir -p "$GADGET_DIR/configs/c.1" || error_exit "Failed to create config directory."

# Add mass storage function
mkdir -p "$GADGET_DIR/functions/mass_storage.0" || error_exit "Failed to create mass_storage.0 function."
echo "$USB_IMAGE" > "$GADGET_DIR/functions/mass_storage.0/lun.0/file"
echo 0 > "$GADGET_DIR/functions/mass_storage.0/lun.0/removable"
echo 1 > "$GADGET_DIR/functions/mass_storage.0/lun.0/nofua"

# Link function to config
ln -s "$GADGET_DIR/functions/mass_storage.0" "$GADGET_DIR/configs/c.1/" || error_exit "Failed to link mass_storage.0 to config."

# Enable the gadget
UDC=$(ls /sys/class/udc | head -n1) || error_exit "No UDC found."
if [ -z "$UDC" ]; then
    error_exit "No UDC found. Please ensure USB OTG is enabled and a UDC is present."
fi

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

# Variables
VID="abcd"                           # Vendor ID from working USB (without 0x)
PID="1234"                           # Product ID from working USB (without 0x)
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

# Clean up any existing functions and configurations
if [ -d "$GADGET_DIR" ]; then
    echo "Cleaning up existing gadget..."

    # Disable the gadget by unbinding the UDC
    if [ -w "$GADGET_DIR/UDC" ]; then
        echo "" > "$GADGET_DIR/UDC"
    fi

    # Wait until the UDC is unbound
    UDC_BOUND=$(cat "$GADGET_DIR/UDC" 2>/dev/null || echo "")
    while [ -n "$UDC_BOUND" ]; do
        echo "Waiting for UDC to unbind..."
        sleep 1
        UDC_BOUND=$(cat "$GADGET_DIR/UDC" 2>/dev/null || echo "")
    done

    # Remove all functions
    if [ -d "$GADGET_DIR/functions/" ]; then
        FUNCTIONS=$(ls "$GADGET_DIR/functions/")
        for FUNC in $FUNCTIONS; do
            rm -rf "$GADGET_DIR/functions/$FUNC" || echo "Warning: Failed to remove function $FUNC"
        done
    fi

    # Remove all configurations
    if [ -d "$GADGET_DIR/configs/" ]; then
        CONFIGS=$(ls "$GADGET_DIR/configs/")
        for CFG in $CONFIGS; do
            rm -rf "$GADGET_DIR/configs/$CFG" || echo "Warning: Failed to remove config $CFG"
        done
    fi

    # Remove all strings
    if [ -d "$GADGET_DIR/strings/" ]; then
        rm -rf "$GADGET_DIR/strings/"* || echo "Warning: Failed to remove strings"
    fi

    # Finally, remove the gadget directory
    rm -rf "$GADGET_DIR" || exit 1
fi

# Create gadget directory if not exists
mkdir -p "$GADGET_DIR" || exit 1

# Set Vendor and Product ID
echo "$VID" > "$GADGET_DIR/idVendor"
echo "$PID" > "$GADGET_DIR/idProduct"

# Set USB and device version
echo "$bcdUSB" > "$GADGET_DIR/bcdUSB"
echo "$bcdDevice" > "$GADGET_DIR/bcdDevice"

# Create English strings
mkdir -p "$GADGET_DIR/strings/0x409" || exit 1
echo "$SERIALNUMBER" > "$GADGET_DIR/strings/0x409/serialnumber"
echo "$MANUFACTURER" > "$GADGET_DIR/strings/0x409/manufacturer"
echo "$PRODUCT" > "$GADGET_DIR/strings/0x409/product"

# Create configuration
mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409" || exit 1
echo "Config 1: Mass Storage" > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
mkdir -p "$GADGET_DIR/configs/c.1" || exit 1

# Add mass storage function
mkdir -p "$GADGET_DIR/functions/mass_storage.0" || exit 1
echo "$USB_IMAGE" > "$GADGET_DIR/functions/mass_storage.0/lun.0/file"
echo 0 > "$GADGET_DIR/functions/mass_storage.0/lun.0/removable"
echo 1 > "$GADGET_DIR/functions/mass_storage.0/lun.0/nofua"

# Link function to config
ln -s "$GADGET_DIR/functions/mass_storage.0" "$GADGET_DIR/configs/c.1/" || exit 1

# Enable the gadget
UDC=$(ls /sys/class/udc | head -n1)
echo "$UDC" > "$GADGET_DIR/UDC"
EOF

# Make the script executable
echo "Making usb-gadget.sh executable..."
chmod +x /usr/bin/usb-gadget.sh || error_exit "Failed to make usb-gadget.sh executable."

# Reload systemd daemon and enable the service
echo "Reloading systemd daemon..."
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."

echo "Enabling USB gadget systemd service..."
systemctl enable usb-gadget.service || error_exit "Failed to enable usb-gadget.service."

# Run the USB gadget setup now
echo "Running USB gadget setup..."
/usr/bin/usb-gadget.sh || error_exit "USB gadget setup failed."

# Final message and reboot
echo ""
echo "USB mass storage setup is complete."
echo "The system will reboot now to apply changes."
echo "=========================================================="
echo ""
reboot now
