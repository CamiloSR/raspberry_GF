#!/home/pi/venv/bin/python3

import time
from datetime import datetime, timedelta

# Path to the file
file_path = "/Volumes/ABGAMMA1/LOGGER.GAM"
file_path = r"D:\LOGGER.GAM"

def get_last_line(file_path):
    """Reads the last line of the file."""
    with open(file_path, 'r') as file:
        lines = file.readlines()
        return lines[-1].strip() if lines else None

def add_two_seconds_to_timestamp_and_increment_value(line):
    """Adds 2 seconds to the timestamp and increments the second-to-last value in the given line."""
    parts = line.split(";")
    if len(parts) > 1:
        # Update the timestamp
        timestamp = parts[0]
        dt = datetime.strptime(timestamp, "%d-%m-%Y %H:%M:%S")
        new_dt = dt + timedelta(seconds=2)
        parts[0] = new_dt.strftime("%d-%m-%Y %H:%M:%S")

        # Increment the second-to-last value
        try:
            second_last_index = -2  # Index for the second-to-last value
            parts[second_last_index] = str(int(parts[second_last_index]) + 1)
        except ValueError:
            print(f"Error incrementing second-to-last value: {parts[second_last_index]}")
        
        return ";".join(parts)
    return line

def write_to_file(file_path, line):
    """Writes a new line to the file."""
    with open(file_path, 'a') as file:  # Append mode
        file.write(line + "\n")

def main():
    last_line = get_last_line(file_path)
    if last_line:
        print(f"Original line: {last_line}")
        while True:
            new_line = add_two_seconds_to_timestamp_and_increment_value(last_line)
            write_to_file(file_path, new_line)  # Append the updated line to the file
            last_line = new_line
            # print(f"Updated line written: {new_line}")
            time.sleep(2)  # Ensure a 2-second break between lines
            
if __name__ == "__main__":
    main()
