#!/bin/bash

# Download latest from github: 
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

# Set your desired USB image name here
USB_IMAGE_NAME="PiUSB_GAMMA_CALMAR"

# Download the watchdog script
wget https://raw.githubusercontent.com/omiq/piusb/main/usb_share_watchdog.py -O usb_share_watchdog.py

# Enable dwc2 overlay and module
echo "dtoverlay=dwc2" >> /boot/config.txt
echo "dwc2" >> /etc/modules

# Set the size as appropriate (in megabytes)
# Example sizes:
# 1GB   = 1024
# 2GB   = 2048
# 4GB   = 4096
USB_SIZE_MB=2048  # Adjust this value as needed

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
mkdir -p /mnt/usbstick
chmod +w /mnt/usbstick
echo "/piusb.bin /mnt/usbstick vfat rw,users,user,exec,umask=000 0 0" >> /etc/fstab
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

[usbstick]
   comment = PiUSB
   path = /mnt/usbstick
   browseable = yes
   writeable = yes
   guest ok = yes
   create mask = 0777
   directory mask = 0755
   force user = root
   force group = root
   public = yes
   only guest = yes
   kernel oplocks = yes
   oplocks = False
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
sed -i '/^exit 0/i sudo /usr/bin/python3 /usr/local/share/usb_share_watchdog.py &' /etc/rc.local

# Start the watchdog script immediately
sudo /usr/bin/python3 /usr/local/share/usb_share_watchdog.py &

# Fin?
echo ""
echo "Done! The system will reboot now ..."
echo "=========================================================="
echo ""
echo ""
reboot now
