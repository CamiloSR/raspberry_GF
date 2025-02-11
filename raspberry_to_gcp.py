import time
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo
from google.cloud import bigquery, firestore
from google.oauth2 import service_account
from collections import deque

# ============================
#         Configuration
# ============================

# Path to the log file. # mtools path
LOG_FILE = "p:/LOGGER.GAM"                 

# Machine and Location Information
MACHINE_NAME = "UIP 2 - Coteau [G50-H]"        # Name of the machine
CURRENT_LOCATION = "Coteau-du-Lac"          # Current location name
LOCATION_INFO = "POINT(-74.1771 45.3053)"   # Geographical coordinates of the location

# Google Cloud Configuration
SERVICE_ACCOUNT_FILE = "gf-iot-csr.json"    # Path to the service account JSON file
PROJECT_ID = "gf-canada-iot"                 # Google Cloud project ID
DATASET_ID = "GF_CAN_Machines"               # BigQuery dataset ID
TABLE_ID = "gamma-machines-pi"                  # BigQuery table ID
FIRESTORE_COLLECTION = "gamma_machines_status" # Firestore collection name

# ============================
#       Timezone Mapping
# ============================

# Dictionary mapping locations to their respective timezones
TIMEZONES = {
    "Coteau-du-Lac": "America/Toronto",
    "Calmar": "America/Edmonton"
}

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
#        Function Definitions
# ============================

def get_log_lines():
    """
    Retrieves the content of LOGGER.GAM using mtype and returns it as a list of lines.
    
    Returns:
        list: A list of strings, each representing a line from LOGGER.GAM.
    """
    try:
        # Execute the mtype command to read LOGGER.GAM
        result = subprocess.run(
            ["mtype", LOG_FILE],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True  # Ensures the output is returned as a string
        )
        # Split the output into lines
        lines = result.stdout.strip().split('\n')
        return lines
    except subprocess.CalledProcessError as e:
        # Handle errors from mtype command
        print(f"mtype command failed: {e.stderr.strip()}")
        return []
    except FileNotFoundError:
        # Handle case where mtype is not installed
        print("mtype command not found. Please install mtools.")
        return []

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
        local_tz = ZoneInfo(TIMEZONES.get(CURRENT_LOCATION, "UTC"))
        
        # Parse the original timestamp with timezone
        now = datetime.now(local_tz)
        
        # Convert timestamp to UTC
        now_utc = now.astimezone(ZoneInfo("UTC"))
        formatted_timestamp = now_utc.isoformat()
        
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

def update_firestore(data, previous_status):
    """
    Updates a Firestore document with the latest status and timestamp.

    Parameters:
        data (dict): The data containing status and timestamp information.
    """
    # Reference to the specific document in the Firestore collection
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
    try:
        # Update the document with location, status, and timestamp
        ts = datetime.fromisoformat(data["Timestamp"])
        if previous_status != data["Status"]:
            doc_ref.set({
                "Location": data["Location Name"],
                "Status": data["Status"],
                "Timestamp": ts,
                "PI_Timestamp" : ts
            })
        if previous_status == data["Status"]:
            doc_ref.update({
                "PI_Timestamp" : ts
            })
    except Exception as e:
        # Handle exceptions during the Firestore update
        print(f"Firestore update error: {e}")
        
def get_latest_sent():
    query = f"""
        SELECT * FROM `{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}`
        WHERE `Location Name` = @current_location AND `Machine` = @machine_name
        ORDER BY Timestamp DESC
        LIMIT 1
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("current_location", "STRING", CURRENT_LOCATION),
            bigquery.ScalarQueryParameter("machine_name", "STRING", MACHINE_NAME)
        ]
    )
    query_job = bigquery_client.query(query, job_config=job_config)
    results = query_job.result()
    for row in results:
        return dict(row)
    return None

last_sent = get_latest_sent()
# print(last_sent)

def continuously_monitor(interval=1):
    """
    Continuously monitors the LOGGER.GAM file for changes and processes new entries.

    Parameters:
        interval (int): Time in seconds between each check of the log file.
    """
    global last_sent
    # Initialize a deque to store the last three lines of the log file
    last_three = deque(maxlen=3)
    
    while True:
        try:
            # Retrieve the current lines from LOGGER.GAM using mtype
            lines = get_log_lines()

            # Clear the deque and append the latest lines
            last_three.clear()
            for line in lines:
                last_three.append(line)
            
            # If there are at least three lines, process the last two
            if len(last_three) == 3:
                third_last, _, last = last_three

                # Process The information from the last lines otherwise
                try:
                    # Extract the second last value from the new line and the third last line
                    last_digit = int(last.strip().split(";")[-2])
                    third_last_digit = int(third_last.strip().split(";")[-2])
                    
                    # Determine the status based on the digits
                    status = "Running" if last_digit != third_last_digit and last_digit != 0 else "Stopped"
                    
                    # Append the status to the new line
                    last_with_status = f"{last.strip()};{status}"
                    
                    previous_status = last_sent.get('Status') if last_sent is not None else None
                    
                    # Parse the modified log line
                    data = parse_log_line(last_with_status)
                    
                    if data:
                        # Send the parsed data to BigQuery and update Firestore
                        update_firestore(data, previous_status)
                        if data == last_sent:
                            continue  
                        send_to_bigquery(data)
                        
                        last_sent = data  # Update last_sent
                except (ValueError, IndexError) as e:
                    # Handle any errors during line processing
                    print(f"Line processing error: {e}")  
                
        except Exception as e:
            # Handle any unexpected errors during monitoring
            print(f"Monitoring error: {e}")
        
        # Wait for the specified interval before checking again
        time.sleep(interval)

# ============================
#         Main Execution
# ============================

if __name__ == "__main__":
    # Start monitoring the log file when the script is executed
    continuously_monitor()
