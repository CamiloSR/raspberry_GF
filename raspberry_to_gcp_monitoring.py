import time
import random
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo
from google.cloud import bigquery, firestore
from google.oauth2 import service_account

# ============================
#      Configuration
# ============================
MACHINE_NAME = "PI Zero Home Test - MTL"             # Name of the machine
CURRENT_LOCATION = "Montreal"                        # Location name (str)
LOCATION_INFO = "POINT(-73.5961598 45.4748343)"      # Geographical coordinates (str)

SERVICE_ACCOUNT_FILE = "2-auth-key.json"             # Path to GCP service account file (str)
PROJECT_ID = "gf-canada-iot"                         # GCP project ID (str)
DATASET_ID = "GF_CAN_Machines"                       # BigQuery dataset ID (str)
TABLE_ID = "pi-monitoring"                           # BigQuery table ID (str)
FIRESTORE_COLLECTION = "gamma_machines_status"       # Firestore collection name (str)

# Initialize credentials and clients for BigQuery and Firestore
credentials = service_account.Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE)
bigquery_client = bigquery.Client(project=PROJECT_ID, credentials=credentials)
firestore_client = firestore.Client(project=PROJECT_ID, credentials=credentials)

def reinitialize_gcp_auth_session() -> None:
    """
    Reinitialize the GCP authentication session by reloading credentials and 
    reinitializing the BigQuery and Firestore clients.
    
    Returns:
        None
    """
    global bigquery_client, firestore_client, credentials
    credentials = service_account.Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE)
    bigquery_client = bigquery.Client(project=PROJECT_ID, credentials=credentials)
    firestore_client = firestore.Client(project=PROJECT_ID, credentials=credentials)
    print("Reinitialized GCP auth session.")

def reset_wifi() -> None:
    """
    Reset the WiFi connection by toggling the 'wlan0' interface and restarting 
    networking services.
    
    Returns:
        None
    """
    subprocess.run(["sudo", "ifconfig", "wlan0", "down"])
    time.sleep(5)
    subprocess.run(["sudo", "ifconfig", "wlan0", "up"])
    subprocess.run(["sudo", "systemctl", "restart", "networking"])
    subprocess.run(["sudo", "systemctl", "restart", "dhcpcd"])
    print("WiFi reset executed.")

def generate_timestamp() -> str:
    """
    Generate a UTC timestamp string in the format 'YYYY-MM-DD HH:MM:SS.ffffff UTC'.
    
    Returns:
        str: Formatted UTC timestamp.
    """
    return datetime.now(ZoneInfo("UTC")).strftime("%Y-%m-%d %H:%M:%S.%f UTC")

def retry_operation(operation, *args, max_retries: int = 5, base_delay: float = 1, **kwargs):
    """
    Retry an operation using exponential backoff.

    Args:
        operation (callable): The function to execute.
        *args: Positional arguments for the operation.
        max_retries (int): Maximum retry attempts.
        base_delay (float): Initial delay in seconds before retrying.
        **kwargs: Keyword arguments for the operation.
    
    Returns:
        Any: Result of the successful operation.
    
    Raises:
        Exception: The last exception if all retry attempts fail.
    """
    for attempt in range(max_retries):
        try:
            return operation(*args, **kwargs)
        except Exception as e:
            if attempt == max_retries - 1:
                raise e
            sleep_time = base_delay * (2 ** attempt) + random.uniform(0, 0.1)
            time.sleep(sleep_time)

def update_firestore(doc_ref, data: dict) -> None:
    """
    Update a Firestore document with the provided data.

    Args:
        doc_ref: Firestore document reference.
        data (dict): Data to update the document with.
    
    Returns:
        None
    """
    doc_ref.update(data)

def insert_bigquery_rows(table_id: str, rows: list) -> None:
    """
    Insert rows into a BigQuery table. Raises an exception if errors occur.

    Args:
        table_id (str): Full identifier for the BigQuery table.
        rows (list): List of dictionaries representing rows to insert.
    
    Returns:
        None

    Raises:
        Exception: If BigQuery insertion returns errors.
    """
    errors = bigquery_client.insert_rows_json(table_id, rows)
    if errors:
        raise Exception(f"BigQuery errors: {errors}")

def monitor_and_update_firestore_bigquery(interval: int = 2) -> None:
    """
    Continuously monitor and update Firestore and BigQuery with new timestamp data.
    If updates fail, performs a WiFi reset and reinitializes GCP authentication.

    Args:
        interval (int): Time in seconds between each update cycle.
    
    Returns:
        None
    """
    table_id = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
    
    while True:
        try:
            # Generate timestamp and prepare the data payload
            timestamp = generate_timestamp()
            data = {"Timestamp": timestamp, "Machine": MACHINE_NAME}
            
            # Update Firestore with retry logic
            try:
                # Convert timestamp string to datetime object for Firestore
                ts = datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S.%f UTC")
                retry_operation(update_firestore, doc_ref, {"PI_Timestamp": ts})
            except Exception as e:
                print(f"Firestore update error: {e}")
                reset_wifi()
                reinitialize_gcp_auth_session()
                # Update document reference with the renewed firestore_client
                doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
            
            # Insert data into BigQuery with retry logic
            try:
                retry_operation(insert_bigquery_rows, table_id, [data])
            except Exception as e:
                print(f"BigQuery insert error: {e}")
                reset_wifi()
                reinitialize_gcp_auth_session()
            
        except Exception as e:
            print(f"Monitoring error: {e}")
        
        time.sleep(interval)

if __name__ == "__main__":
    monitor_and_update_firestore_bigquery()
