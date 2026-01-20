# raspberry_GF

/Instructions V2
# PASSW:
pi_csr_123


# STEP 1: CREATE THE FILE: usbsetup.sh from GitHub and excecute it:
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/0_setup_v4.sh -O usbsetup.sh

sudo dos2unix usbsetup.sh

sudo chmod +x usbsetup.sh

sudo ./usbsetup.sh


# RUN THESE COMMANDS (THIS WILL EXECUTE IN ROOT)\
sudo su

<!-- # Stop Using g_mass_storage, Unmount and unbind it: -->
echo "" > /sys/kernel/config/usb_gadget/g1/UDC
modprobe -r g_mass_storage

<!-- # PREVENT G_MASS_STORAGE FROM LOADING AT BOOT, EDIT /ETC/MODULES AND COMMENT OUT G_MASS_STORAGE: -->
sudo nano /etc/modules
# g_mass_storage

<!-- # REMOVE ITS MODPROBE CONFIG: -->
sudo rm /etc/modprobe.d/g_mass_storage.conf

<!-- # EXIT FROM ROOT -->
exit


# NOW CREATE THIS SCRIPT /usr/bin/usb-gadget.sh
<!-- remove only if existed previously: sudo rm /usr/bin/usb-gadget.sh -->
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/1_USB_Gadget_v2.sh -O /usr/bin/usb-gadget.sh
sudo dos2unix /usr/bin/usb-gadget.sh
sudo chmod +x /usr/bin/usb-gadget.sh


# NOW AUTOMATE SERVICE ON BOOT CREATE THE SERVICE FILE...
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/2_usb_gadget.service -O /etc/systemd/system/usb-gadget.service
sudo dos2unix /etc/systemd/system/usb-gadget.service
sudo systemctl daemon-reload
sudo systemctl enable usb-gadget.service

sudo reboot


# Generate LOGGER.GAM file with header and sample data on USB storage if not present on the USB mass storage device
if ! mdir p:/ | grep -qi "LOGGER.GAM"; then
    echo "Creating LOGGER.GAM file on USB storage..."
    cat <<EOF > /tmp/LOGGER.GAM
GAMA LOG TYPE: G-250 H D;VERSION: 090617;METRIC: N
03-02-2025 12:54:56;91597;82;80;90;88;81;69;500;1;0;0;620;770;940;0
03-02-2025 12:54:58;91597;82;80;90;88;81;69;500;1;0;0;630;790;940;0
03-02-2025 12:55:00;91597;82;80;89;88;81;69;500;1;0;0;620;790;941;0
EOF
    mcopy /tmp/LOGGER.GAM p:/LOGGER.GAM || error_exit "Failed to create LOGGER.GAM file"
    rm /tmp/LOGGER.GAM
fi


# EVALUATE THE SERVICE IF USB WAS NOT INITIATED AUTOMATICALLY:
sudo systemctl status usb-gadget.service
sudo journalctl -xeu usb-gadget.service


# TEST MTOOLS & EXPECTED OUTPUT:
mdir p:/
<!-- 

 Volume in drive P is PIUSB
 Volume Serial Number is AA37-5F8B
Directory for P:/

LOGGER   GAM       255 2025-04-23  11:19
        1 file                  255 bytes
                      2 143 252 480 bytes free

-->

### HERE WE END THE 

# STEP 7: INSTALL PYTHON DEPENDENCIES
cd /home/pi/
python3 -m venv venv
source venv/bin/activate

source /home/pi/venv/bin/activate

pip cache purge
pip install --no-cache-dir google-cloud-bigquery google-cloud-firestore google-auth pytz



# MAKE SURE TO CREATE THIS CREDENTIALS JSON FILE:
sudo nano /home/pi/2-auth-key.json

<!-- 
paste the content of the Credentials json File "2-auth-key.json" or whatever name it has in your local machine...
-->

sudo dos2unix /home/pi/2-auth-key.json


# Create the SCRIPT:
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/3_raspberry_to_gcp.py -O /home/pi/raspberry_to_gcp.py
sudo dos2unix /home/pi/raspberry_to_gcp.py
sudo chmod +x /home/pi/raspberry_to_gcp.py


# FOR TESTING ONLY:
source venv/bin/activate
python3 /home/pi/raspberry_to_gcp.py


# STEP 8: CREATE / MODIFIY the SYSTEM Service File, RELOAD and RESTART the SYSTEM SERVICES
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/4_raspberry_to_gcp.service -O /etc/systemd/system/raspberry_to_gcp.service
sudo dos2unix /etc/systemd/system/raspberry_to_gcp.service
sudo systemctl daemon-reload
sudo systemctl enable raspberry_to_gcp.service
sudo systemctl start raspberry_to_gcp.service


# CHECK THE STATUS OF THE SERVICE
sudo systemctl status raspberry_to_gcp.service
sudo journalctl -u raspberry_to_gcp.service -b


###### ALL SET
# VERIFY CONFIGURATION AND USEFUL COMMANDS
# TO LIST FILES IN THE DIRECTORY:
mdir p:/

# TO ACCESS THE LAST LINE OF A FILE:
mtype p:/LOGGER.GAM | tail -n 1

# To stop and disable the service
sudo systemctl stop raspberry_to_gcp.service
sudo systemctl restart raspberry_to_gcp.service
sudo systemctl disable raspberry_to_gcp.service
