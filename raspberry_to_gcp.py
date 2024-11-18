import time
from datetime import datetime
from zoneinfo import ZoneInfo
from google.cloud import bigquery, firestore
from google.oauth2 import service_account
from collections import deque

# ============================
#         Configuration
# ============================

# Path to the log file.
# Note: Only the last assignment will take effect.
# LOG_FILE = "LOGGER.GAM"                  # Initial log file path
LOG_FILE = "/mnt/p/LOGGER.GAM"           # Mounted log file path
# LOG_FILE = "D:\LOGGER.GAM"               # Final log file path (this is the active one)

# Machine and Location Information
MACHINE_NAME = "CDL Line 1 [Gamma]"      # Name of the machine
CURRENT_LOCATION = "Coteau-du-Lac"        # Current location name
LOCATION_INFO = "POINT(-74.1771 45.3053)" # Geographical coordinates of the location

# Google Cloud Configuration
SERVICE_ACCOUNT_FILE = "gf-iot-csr.json"  # Path to the service account JSON file
PROJECT_ID = "gf-canada-iot"               # Google Cloud project ID
DATASET_ID = "GF_CAN_Machines"             # BigQuery dataset ID
TABLE_ID = "gamma-machines"                # BigQuery table ID
FIRESTORE_COLLECTION = "gamma_machines_status" # Firestore collection name

# ============================
#     Initialize Clients
# ============================

# Load credentials from the service account file
credentials = service_account.Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE)

# Initialize the BigQuery client with the project ID and credentials
bigquery_client = bigquery.Client(project=PROJECT_ID, credentials=credentials)

# Initialize the Firestore client with the project ID and credentials
firestore_client = firestore.Client(project=PROJECT_ID, credentials=credentials)

# ============================
#       Timezone Mapping
# ============================

# Dictionary mapping locations to their respective timezones
TIMEZONES = {
    "Coteau-du-Lac": "America/Toronto",
    "Calmar": "America/Edmonton"
}

# ============================
#        Function Definitions
# ============================

def parse_log_line(log_line):
    """
    Parses a single line from the log file and converts it into a dictionary
    with appropriate data types and additional metadata.

    Parameters:
        log_line (str): A line from the log file.

    Returns:
        dict or None: Parsed data as a dictionary if successful, else None.
    """
    # Split the log line by semicolon to extract individual values
    values = log_line.split(";")
    
    # Check if the log line has the expected number of values
    if len(values) < 17:
        print(f"Invalid log line: {log_line}")
        return None
    try:
        # Extract and parse the original timestamp
        original_timestamp = values[0]
        dt = datetime.strptime(original_timestamp, "%d-%m-%Y %H:%M:%S").replace(tzinfo=ZoneInfo("UTC"))
        
        # Convert timestamp to the appropriate timezone based on current location
        dt = dt.astimezone(ZoneInfo(TIMEZONES.get(CURRENT_LOCATION, "UTC")))
        formatted_timestamp = dt.isoformat()
        
        # Create and return a dictionary with all required fields
        return {
            "Timestamp": formatted_timestamp,
            "Minute ID": int(values[1]),
            "ISO Temp Real": float(values[2]),
            "ISO Temp Set": float(values[3]),
            "RESIN Temp Real": float(values[4]),
            "RESIN Temp Set": float(values[5]),
            "HOSE Temp Real": float(values[6]),
            "HOSE Temp Set": float(values[7]),
            "Value8": float(values[8]),
            "Value9": float(values[9]),
            "ISO Amperage": float(values[10]),
            "RESIN Amperage": float(values[11]),
            "ISO Pressure": float(values[12]),
            "RESIN Pressure": float(values[13]),
            "Counter": int(values[14]),
            "Value15": float(values[15]),
            "Status": values[16],
            "Machine": MACHINE_NAME,
            "Location": LOCATION_INFO,
            "Location Name": CURRENT_LOCATION,
        }
    except ValueError as e:
        # Handle any errors during timestamp parsing
        print(f"Timestamp parse error: {e}")
        return None

def send_to_bigquery(data):
    """
    Inserts a single row of data into the specified BigQuery table.

    Parameters:
        data (dict): The data to be inserted into BigQuery.
    """
    # Construct the full table ID in the format project.dataset.table
    table_id = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"
    try:
        # Insert the data as a JSON row
        errors = bigquery_client.insert_rows_json(table_id, [data])
        if errors:
            # Print any errors returned by BigQuery
            print(f"BigQuery errors: {errors}")
    except Exception as e:
        # Handle exceptions during the insert operation
        print(f"BigQuery insert exception: {e}")

def update_firestore(data):
    """
    Updates a Firestore document with the latest status and timestamp.

    Parameters:
        data (dict): The data containing status and timestamp information.
    """
    # Reference to the specific document in the Firestore collection
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
    try:
        # Update the document with location, status, and timestamp
        doc_ref.set({
            "Location": data["Location Name"],
            "Status": data["Status"],
            "Timestamp": datetime.fromisoformat(data["Timestamp"])
        })
    except Exception as e:
        # Handle exceptions during the Firestore update
        print(f"Firestore update error: {e}")

def process_line(last_line, new_line):
    """
    Processes the latest line from the log file by determining the machine's status
    and sending the data to BigQuery and Firestore.

    Parameters:
        last_line (str): The third last line from the log file.
        new_line (str): The most recent line from the log file.
    """
    try:
        # Extract the second last value from the new line and the third last line
        last_digit = int(new_line.strip().split(";")[-2])
        third_last_digit = int(last_line.strip().split(";")[-2])
        
        # Determine the status based on the digits
        status = "Running" if last_digit != third_last_digit and last_digit != 0 else "Stopped"
        
        # Append the status to the new line
        new_line_with_status = f"{new_line.strip()};{status}"
        
        # Parse the modified log line
        data = parse_log_line(new_line_with_status)
        
        if data:
            # Send the parsed data to BigQuery and update Firestore
            send_to_bigquery(data)
            update_firestore(data)
    except (ValueError, IndexError) as e:
        # Handle any errors during line processing
        print(f"Line processing error: {e}")

def continuously_monitor(interval=1):
    """
    Continuously monitors the log file for changes and processes new entries.

    Parameters:
        interval (int): Time in seconds between each check of the log file.
    """
    # Initialize a deque to store the last three lines of the log file
    last_three = deque(maxlen=3)
    
    while True:
        try:
            # Open the log file in read mode
            with open(LOG_FILE, 'r') as file:
                # Read each line and append it to the deque
                for line in file:
                    last_three.append(line)
            
            # If there are at least three lines, process the last two
            if len(last_three) == 3:
                third_last, _, last = last_three
                process_line(third_last, last)
        except Exception as e:
            # Handle any errors during file monitoring
            print(f"Monitoring error: {e}")
        
        # Wait for the specified interval before checking again
        time.sleep(interval)

# ============================
#         Main Execution
# ============================

if __name__ == "__main__":
    # Start monitoring the log file when the script is executed
    continuously_monitor()
