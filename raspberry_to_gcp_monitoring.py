import time
import random
from datetime import datetime
from zoneinfo import ZoneInfo
from google.cloud import bigquery, firestore
from google.oauth2 import service_account

# ============================
#      Configuration
# ============================
MACHINE_NAME = "UIP 1 - Calmar [G50-H]"         # Machine identifier
CURRENT_LOCATION = "Calmar"                       # Location name
LOCATION_INFO = "POINT(-113.8070872 53.2569529)"    # Geographical coordinates

SERVICE_ACCOUNT_FILE = "2-auth-key.json"
PROJECT_ID = "gf-canada-iot"
DATASET_ID = "GF_CAN_Machines"
TABLE_ID = "pi-monitoring"
FIRESTORE_COLLECTION = "gamma_machines_status"

# Initialize credentials and clients for BigQuery and Firestore
credentials = service_account.Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE)
bigquery_client = bigquery.Client(project=PROJECT_ID, credentials=credentials)
firestore_client = firestore.Client(project=PROJECT_ID, credentials=credentials)

def reinitialize_gcp_auth_session():
    """
    Reinitialize the GCP authentication session by reloading the credentials
    and reinitializing BigQuery and Firestore clients.
    """
    global bigquery_client, firestore_client, credentials
    credentials = service_account.Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE)
    bigquery_client = bigquery.Client(project=PROJECT_ID, credentials=credentials)
    firestore_client = firestore.Client(project=PROJECT_ID, credentials=credentials)
    print("Reinitialized GCP auth session.")

def generate_timestamp():
    """
    Generate a UTC timestamp string in the format 'YYYY-MM-DD HH:MM:SS.ffffff UTC'.
    """
    return datetime.now(ZoneInfo("UTC")).strftime("%Y-%m-%d %H:%M:%S.%f UTC")

def retry_operation(operation, *args, max_retries=5, base_delay=1, **kwargs):
    """
    Retry an operation using exponential backoff.
    
    Parameters:
      operation: The function to execute.
      *args, **kwargs: Arguments for the operation.
      max_retries: Maximum retry attempts.
      base_delay: Initial delay in seconds.
      
    Raises:
      The last exception if all retry attempts fail.
    """
    for attempt in range(max_retries):
        try:
            return operation(*args, **kwargs)
        except Exception as e:
            if attempt == max_retries - 1:
                raise e
            sleep_time = base_delay * (2 ** attempt) + random.uniform(0, 0.1)
            time.sleep(sleep_time)

def update_firestore(doc_ref, data):
    """
    Update a Firestore document with the provided data.
    """
    doc_ref.update(data)

def insert_bigquery_rows(table_id, rows):
    """
    Insert rows into BigQuery and raise an exception if errors occur.
    """
    errors = bigquery_client.insert_rows_json(table_id, rows)
    if errors:
        raise Exception(f"BigQuery errors: {errors}")

def monitor_and_update_firestore_bigquery(interval=2):
    """
    Continuously monitor and update Firestore and BigQuery with new timestamp data.
    
    Parameters:
      interval: Time in seconds between each update cycle.
    """
    table_id = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
    
    while True:
        try:
            # Generate timestamp and prepare the data payload
            timestamp = generate_timestamp()
            data = {
                "Timestamp": timestamp,
                "Machine": MACHINE_NAME,
            }
            # Attempt to update Firestore with retry logic
            try:
                ts = datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S.%f UTC")
                retry_operation(update_firestore, doc_ref, {"PI_Timestamp": ts})
            except Exception as e:
                print(f"Firestore update error: {e}")
                # Reinitialize the GCP auth session on failure
                reinitialize_gcp_auth_session()
                # Update doc_ref with the renewed firestore_client
                doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
            
            # Attempt to insert data into BigQuery with retry logic
            try:
                retry_operation(insert_bigquery_rows, table_id, [data])
            except Exception as e:
                print(f"BigQuery insert error: {e}")
                # Reinitialize the GCP auth session on failure
                reinitialize_gcp_auth_session()
            
        except Exception as e:
            print(f"Monitoring error: {e}")
        
        time.sleep(interval)

if __name__ == "__main__":
    monitor_and_update_firestore_bigquery()
