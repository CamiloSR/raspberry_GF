#!/bin/bash

# Download latest from GitHub: 
# wget https://raw.githubusercontent.com/omiq/piusb/main/setup.sh -O setup.sh
# chmod +x setup.sh
# sudo ./setup.sh

if [[ $EUID -ne 0 ]]; then
    echo ""
    echo "_______________________________"
    echo "Please use sudo or run as root."
    echo "==============================="
    echo ""
    echo ""
    exit
fi

# Set your desired USB image name here (this will be used for the volume label, mount point, and Samba share name)
USB_IMAGE_NAME="piusb_calmar_gamma_1"

# Download the watchdog script
wget https://raw.githubusercontent.com/omiq/piusb/main/usb_share_watchdog.py -O usb_share_watchdog.py

# Enable dwc2 overlay and module
echo "dtoverlay=dwc2" >> /boot/config.txt
echo "dwc2" >> /etc/modules

# Set the size as appropriate (in megabytes)
# Example sizes:
# 1GB   = 1024
# 16GB  = 16384
# 32GB  = 32768
USB_SIZE_MB=1024  # Adjust this value as needed

echo ""
echo ""
echo "Creating the USB stick storage. This might take some time!"
echo "=========================================================="
echo ""
echo ""
dd bs=1M if=/dev/zero of=/piusb.bin count=$USB_SIZE_MB
mkdosfs -F 32 --mbr=yes -n "$USB_IMAGE_NAME" /piusb.bin
echo ""
echo ""
echo "USB storage created. Continuing configuration ..."
echo "=========================================================="
echo ""
echo ""

# Create the mount point and mount the storage
echo ""
echo "Mounting the storage"
echo "=========================================================="
echo ""
MOUNT_POINT="/mnt/$USB_IMAGE_NAME"
mkdir -p "$MOUNT_POINT"
chmod +w "$MOUNT_POINT"
echo "/piusb.bin $MOUNT_POINT vfat rw,users,user,exec,umask=000 0 0" >> /etc/fstab
systemctl daemon-reload
mount -a
sudo modprobe g_mass_storage file=/piusb.bin stall=0 ro=0

# Update package lists and install dependencies
echo ""
echo "Installing dependencies"
echo "=========================================================="
echo ""
apt-get update
apt-get install python3 -y
apt-get install samba -y
apt-get install winbind -y
apt-get install python3-watchdog -y

# Configure Samba share
echo ""
echo "Creating Samba share"
echo "=========================================================="
echo ""
cat <<EOT >> /etc/samba/smb.conf

[$USB_IMAGE_NAME]
   comment = PiUSB
   path = $MOUNT_POINT
   browseable = yes
   read only = yes
   guest ok = yes
   create mask = 0777
   directory mask = 0755
   public = yes
EOT

systemctl restart smbd.service

# Set up the watchdog script
echo ""
echo "Setting up watchdog"
echo "=========================================================="
echo ""
cp usb_share_watchdog.py /usr/local/share/
chmod +x /usr/local/share/usb_share_watchdog.py

# Ensure /etc/rc.local exists and is executable
if [ ! -f /etc/rc.local ]; then
    echo "#!/bin/bash" > /etc/rc.local
    chmod +x /etc/rc.local
fi

# Add the watchdog script to /etc/rc.local before the 'exit 0' line
if ! grep -q "usb_share_watchdog.py" /etc/rc.local; then
    sed -i '/^exit 0/i sudo /usr/bin/python3 /usr/local/share/usb_share_watchdog.py &' /etc/rc.local
fi

# Start the watchdog script immediately
sudo /usr/bin/python3 /usr/local/share/usb_share_watchdog.py &

# Fin?
echo ""
echo "Done! The system will reboot now ..."
echo "=========================================================="
echo ""
echo ""
reboot now
