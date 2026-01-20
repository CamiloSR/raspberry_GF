# raspberry_GF

## Instructions V2

### Password
```
pi_csr_123
```

---

## STEP 1: Create and Execute USB Setup Script

Download and execute the initial setup script from GitHub:

```bash
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/0_pizero2w_setup.sh -O usbsetup.sh
sudo dos2unix usbsetup.sh
sudo chmod +x usbsetup.sh
sudo ./usbsetup.sh
```

---

## STEP 2: Unload Legacy Gadget Module

Execute the following commands to unload the legacy gadget and prevent auto-loading at boot:

```bash
# Unload legacy gadget (safe if not loaded)
sudo modprobe -r g_mass_storage || true

# Make sure it won't auto-load at boot
sudo sed -i 's/^[[:space:]]*g_mass_storage[[:space:]]*$/# g_mass_storage/' /etc/modules

# Remove legacy module options file (if it exists)
sudo rm -f /etc/modprobe.d/g_mass_storage.conf
```

Then reboot:
```bash
sudo reboot
```

---

## STEP 3: Stop Using g_mass_storage

Switch to root and disable g_mass_storage:

```bash
sudo su

# Stop using g_mass_storage, unmount and unbind it
echo "" > /sys/kernel/config/usb_gadget/g1/UDC
modprobe -r g_mass_storage
```

Edit `/etc/modules` and comment out `g_mass_storage`:

```bash
sudo nano /etc/modules
```

Add `#` before `g_mass_storage`:
```
# g_mass_storage
```

Remove the modprobe config:
```bash
sudo rm /etc/modprobe.d/g_mass_storage.conf
```

Exit from root:
```bash
exit
```

---

## STEP 4: Create USB Gadget Script

Download and configure the USB gadget script:

```bash
# Remove only if existed previously: 
# sudo rm /usr/bin/usb-gadget.sh

sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/1_USB_Gadget.sh -O /usr/bin/usb-gadget.sh
sudo dos2unix /usr/bin/usb-gadget.sh
sudo chmod +x /usr/bin/usb-gadget.sh
```

---

## STEP 5: Automate Service on Boot

Create the service file:

```bash
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/2_usb_gadget.service -O /etc/systemd/system/usb-gadget.service
sudo dos2unix /etc/systemd/system/usb-gadget.service
sudo systemctl daemon-reload
sudo systemctl enable usb-gadget.service
sudo reboot
```

---

## STEP 6: Generate LOGGER.GAM File

Generate LOGGER.GAM file with header and sample data on USB storage if not present:

```bash
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
```

---

## STEP 7: Evaluate USB Service Status

Check if USB was initiated automatically:

```bash
sudo systemctl status usb-gadget.service
sudo journalctl -xeu usb-gadget.service
```

---

## STEP 8: Test mtools

Test mtools and verify expected output:

```bash
mdir p:/
```

Expected output:
```
 Volume in drive P is PIUSB
 Volume Serial Number is AA37-5F8B
Directory for P:/

LOGGER   GAM       255 2025-04-23  11:19
        1 file                  255 bytes
                      2 143 252 480 bytes free
```

### End of USB Configuration

---

## STEP 9: Install Python Dependencies

Set up Python virtual environment and install required packages:

```bash
cd /home/pi/
python3 -m venv venv
source venv/bin/activate

pip cache purge
pip install --no-cache-dir google-cloud-bigquery google-cloud-firestore google-auth pytz
```

---

## STEP 10: Create Credentials JSON File

Create the credentials file:

```bash
sudo nano /home/pi/2-auth-key.json
```

Paste the content of your credentials JSON file (`2-auth-key.json`) and save.

Convert line endings:
```bash
sudo dos2unix /home/pi/2-auth-key.json
```

---

## STEP 11: Create Python Script

Download and configure the GCP upload script:

```bash
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/3_raspberry_to_gcp.py -O /home/pi/raspberry_to_gcp.py
sudo dos2unix /home/pi/raspberry_to_gcp.py
sudo chmod +x /home/pi/raspberry_to_gcp.py
```

### Test the Script (Optional)

```bash
source venv/bin/activate
python3 /home/pi/raspberry_to_gcp.py
```

---

## STEP 12: Create System Service

Create/modify the system service file:

```bash
sudo wget https://raw.githubusercontent.com/CamiloSR/raspberry_GF/main/4_raspberry_to_gcp.service -O /etc/systemd/system/raspberry_to_gcp.service
sudo dos2unix /etc/systemd/system/raspberry_to_gcp.service
sudo systemctl daemon-reload
sudo systemctl enable raspberry_to_gcp.service
sudo systemctl start raspberry_to_gcp.service
```

---

## STEP 13: Check Service Status

Verify the service is running:

```bash
sudo systemctl status raspberry_to_gcp.service
sudo journalctl -u raspberry_to_gcp.service -b
```

---

## All Set! 🎉

---

## Useful Commands

### Verify Configuration

List files in the directory:
```bash
mdir p:/
```

Access the last line of a file:
```bash
mtype p:/LOGGER.GAM | tail -n 1
```

### Service Management

Stop the service:
```bash
sudo systemctl stop raspberry_to_gcp.service
```

Restart the service:
```bash
sudo systemctl restart raspberry_to_gcp.service
```

Disable the service:
```bash
sudo systemctl disable raspberry_to_gcp.service
```
