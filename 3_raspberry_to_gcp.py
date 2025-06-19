# /home/pi/raspberry_to_gcp.py
import time
import subprocess
import logging
from datetime import datetime
from zoneinfo import ZoneInfo
from collections import deque
from typing import List, Optional, Dict, Any
from google.cloud import bigquery, firestore
from google.oauth2 import service_account
import google.api_core.exceptions

# ============================
#         Configuration
# ============================

# Path to the log file (mtools path)
LOG_FILE: str = "p:/LOGGER.GAM"

# Machine and Location Information
MACHINE_NAME: str = "UIP 1 - Calmar [G50-H]"  # Name of the machine
CURRENT_LOCATION: str = "Calmar"                # Current location name
LOCATION_INFO: str = "POINT(-113.8070872 53.2569529)"  # Geographical coordinates of the location

# Google Cloud Configuration
SERVICE_ACCOUNT_FILE: str = "2-auth-key.json"   # Path to the service account JSON file
PROJECT_ID: str = "gf-canada-iot"                 # Google Cloud project ID
DATASET_ID: str = "GF_CAN_Machines"               # BigQuery dataset ID
TABLE_ID: str = "gamma-machines-pi"               # BigQuery table ID
FIRESTORE_COLLECTION: str = "gamma_machines_status"  # Firestore collection name

# ============================
#      Retry Configurations
# ============================
MAX_ATTEMPTS_BQ: int = 3            # Maximum attempts for BigQuery
INITIAL_DELAY_BQ: int = 3           # Initial delay (in seconds) for BigQuery retries
MAX_ATTEMPTS_FS: int = 3            # Maximum attempts for Firestore
INITIAL_DELAY_FS: int = 2           # Initial delay (in seconds) for Firestore retries
COOL_DOWN_PERIOD: int = 25          # Cooldown period (in seconds) after repeated failures

# ============================
#       Timezone Mapping
# ============================
# Dictionary mapping locations to their respective timezones
TIMEZONES: Dict[str, str] = {
    "Coteau-du-Lac": "America/Toronto",
    "Calmar": "America/Edmonton"
}

# ============================
#     Initialize Clients
# ============================
# Load credentials from the service account file and initialize the Google Cloud clients
credentials = service_account.Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE)
bigquery_client: bigquery.Client = bigquery.Client(project=PROJECT_ID, credentials=credentials)
firestore_client: firestore.Client = firestore.Client(project=PROJECT_ID, credentials=credentials)

# ============================
#     Logging Configuration
# ============================
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler("iot_update.log"),
        logging.StreamHandler()
    ]
)

# ============================
#     Function Definitions
# ============================

def get_log_lines() -> List[str]:
    """
    Retrieves the content of LOGGER.GAM using mtype and returns it as a list of lines.
    
    Returns:
        List[str]: A list of strings, each representing a line from LOGGER.GAM.
    """
    try:
        result = subprocess.run(
            ["mtype", LOG_FILE],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True  # Ensures output is a string
        )
        lines: List[str] = result.stdout.strip().split('\n')
        return lines
    except subprocess.CalledProcessError as e:
        logging.error("mtype command failed: %s", e.stderr.strip())
        return []
    except FileNotFoundError:
        logging.error("mtype command not found. Please install mtools.")
        return []

def parse_log_line(log_line: str) -> Optional[Dict[str, Any]]:
    """
    Parses a single line from the log file and converts it into a dictionary
    with appropriate data types and additional metadata.

    Parameters:
        log_line (str): A line from the log file.

    Returns:
        dict or None: Parsed data as a dictionary if successful, else None.
    """
    values = log_line.split(";")
    if len(values) < 17:
        logging.error("Invalid log line: %s", log_line)
        return None
    try:
        local_tz = ZoneInfo(TIMEZONES.get(CURRENT_LOCATION, "UTC"))
        now: datetime = datetime.now(local_tz)
        now_utc: datetime = now.astimezone(ZoneInfo("UTC"))
        formatted_timestamp: str = now_utc.isoformat()
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
        logging.error("Timestamp parse error: %s", e)
        return None

def send_to_bigquery(data: Dict[str, Any]) -> None:
    """
    Inserts a single row of data into BigQuery with exponential backoff and circuit breaker logic.

    Parameters:
        data (dict): The data to be inserted into BigQuery.
    """
    table_id: str = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"
    for attempt in range(1, MAX_ATTEMPTS_BQ + 1):
        try:
            errors = bigquery_client.insert_rows_json(table_id, [data])
            if errors:
                logging.error("BigQuery errors on attempt %d: %s", attempt, errors)
            else:
                logging.info("Data inserted into BigQuery successfully on attempt %d.", attempt)
                return  # Exit after successful insert
        except google.api_core.exceptions.GoogleAPIError as e:
            logging.error("GoogleAPIError on BigQuery attempt %d: %s", attempt, e)
        except Exception as e:
            logging.exception("Unexpected error on BigQuery attempt %d", attempt)
        
        if attempt < MAX_ATTEMPTS_BQ:
            delay = INITIAL_DELAY_BQ * (2 ** (attempt - 1))
            logging.debug("Retrying BigQuery insertion in %d seconds (exponential backoff)...", delay)
            time.sleep(delay)
    
    logging.error("Failed to insert data into BigQuery after %d attempts. Triggering circuit breaker cooldown.", MAX_ATTEMPTS_BQ)
    logging.debug("Cooling down for %d seconds.", COOL_DOWN_PERIOD)
    time.sleep(COOL_DOWN_PERIOD)

def update_firestore(data: Dict[str, Any], previous_status: Optional[str]) -> None:
    """
    Updates a Firestore document with exponential backoff and circuit breaker logic.

    Parameters:
        data (dict): The data containing status and timestamp information.
        previous_status (str or None): The previous status to compare against.
    """
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
    ts: datetime = datetime.fromisoformat(data["Timestamp"])
    for attempt in range(1, MAX_ATTEMPTS_FS + 1):
        try:
            if previous_status != data["Status"]:
                doc_ref.set({
                    "Location": data["Location Name"],
                    "Status": data["Status"],
                    "Timestamp": ts,
                    "PI_Timestamp": ts
                })
                logging.info("Firestore document set successfully on attempt %d.", attempt)
            else:
                doc_ref.update({
                    "PI_Timestamp": ts
                })
                logging.info("Firestore document updated successfully on attempt %d.", attempt)
            return  # Exit if successful
        except google.api_core.exceptions.ServiceUnavailable as e:
            logging.error("Firestore ServiceUnavailable on attempt %d: %s", attempt, e)
        except google.api_core.exceptions.GoogleAPIError as e:
            logging.error("Firestore GoogleAPIError on attempt %d: %s", attempt, e)
        except Exception as e:
            logging.exception("Unexpected error on Firestore attempt %d", attempt)
        
        if attempt < MAX_ATTEMPTS_FS:
            delay = INITIAL_DELAY_FS * (2 ** (attempt - 1))
            logging.debug("Retrying Firestore update in %d seconds (exponential backoff)...", delay)
            time.sleep(delay)
    
    logging.error("Failed to update Firestore after %d attempts. Triggering circuit breaker cooldown.", MAX_ATTEMPTS_FS)
    logging.debug("Cooling down for %d seconds.", COOL_DOWN_PERIOD)
    time.sleep(COOL_DOWN_PERIOD)

def get_latest_sent() -> Optional[Dict[str, Any]]:
    """
    Retrieves the latest sent data from BigQuery for the current machine and location.

    Returns:
        dict or None: The most recent row of data as a dictionary if found, else None.
    """
    query: str = f"""
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

def continuously_monitor(interval: int = 1) -> None:
    """
    Continuously monitors the LOGGER.GAM file for changes and processes new entries.

    Parameters:
        interval (int): Time in seconds between each check of the log file.
    """
    global last_sent
    last_three: deque = deque(maxlen=3)
    
    while True:
        try:
            lines: List[str] = get_log_lines()
            last_three.clear()
            for line in lines:
                last_three.append(line)
            
            if len(last_three) == 3:
                third_last, _, last = last_three
                try:
                    last_digit: int = int(last.strip().split(";")[-2])
                    third_last_digit: int = int(third_last.strip().split(";")[-2])
                    status: str = "Running" if last_digit != third_last_digit and last_digit != 0 else "Stopped"
                    last_with_status: str = f"{last.strip()};{status}"
                    previous_status: Optional[str] = last_sent.get('Status') if last_sent is not None else None
                    previous_ts = last_sent.get('PI_Timestamp') if last_sent and 'PI_Timestamp' in last_sent else None
                    data: Optional[Dict[str, Any]] = parse_log_line(last_with_status)
                    
                    # Only update Firestore if status changed OR 5+ min have passed since last update
                    update_needed = False
                    if data:
                        # current_ts = datetime.fromisoformat(data["Timestamp"])
                        if status != previous_status:
                            update_needed = True
                        # elif previous_ts:
                        #     if isinstance(previous_ts, str):
                        #         previous_ts = datetime.fromisoformat(previous_ts)
                        #     if abs((current_ts - previous_ts).total_seconds()) >= 300:
                        #         update_needed = True

                        if update_needed:
                            update_firestore(data, previous_status)
                        if data == last_sent:
                            continue
                        send_to_bigquery(data)
                        last_sent = data
                except (ValueError, IndexError) as e:
                    logging.error("Line processing error: %s", e)
        except Exception as e:
            logging.exception("Monitoring error")
        time.sleep(interval)

# ============================
#         Main Execution
# ============================
if __name__ == "__main__":
    last_sent: Optional[Dict[str, Any]] = get_latest_sent()
    continuously_monitor()
