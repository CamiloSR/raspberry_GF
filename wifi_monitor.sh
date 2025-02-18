#!/bin/bash

LOG_FILE="/home/pi/wifi_logs_csr.csv"

# Create log file with headers if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
    echo "Timestamp,WiFi_Status,Internet_Status,Load_1min,Load_5min,Load_15min,Temp_C" > "$LOG_FILE"
fi

while true; do
    TIMESTAMP=$(date --iso-8601=seconds)  # Get timestamp with timezone
    WIFI_STATUS=$(iwgetid -r)  # Get WiFi SSID, empty if disconnected
    INTERNET_STATUS=$(ping -c 1 -W 1 8.8.8.8 > /dev/null 2>&1 && echo "Online" || echo "Offline")
    
    # Extract different load averages
    read LOAD_1MIN LOAD_5MIN LOAD_15MIN _ < /proc/loadavg

    TEMP_C=$(vcgencmd measure_temp | grep -oP '(?<=temp=)[0-9.]+')  # Get internal temp

    # If no SSID is detected, set WiFi status as "Disconnected"
    [[ -z "$WIFI_STATUS" ]] && WIFI_STATUS="Disconnected"

    # Log to CSV
    echo "$TIMESTAMP,$WIFI_STATUS,$INTERNET_STATUS,$LOAD_1MIN,$LOAD_5MIN,$LOAD_15MIN,$TEMP_C" >> "$LOG_FILE"

    sleep 2  # Run every 2 seconds
done
