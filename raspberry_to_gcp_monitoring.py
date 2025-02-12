import time
from datetime import datetime
from zoneinfo import ZoneInfo
from google.cloud import bigquery, firestore
from google.oauth2 import service_account

# ============================
#         Configuration
# ============================

MACHINE_NAME = "UIP 2 - Coteau [G50-H]"
CURRENT_LOCATION = "Coteau-du-Lac"
LOCATION_INFO = "POINT(-74.1771 45.3053)"

SERVICE_ACCOUNT_FILE = "2-auth-key.json"
PROJECT_ID = "gf-canada-iot"
DATASET_ID = "GF_CAN_Machines"
TABLE_ID = "pi-monitoring"
FIRESTORE_COLLECTION = "gamma_machines_status"

# ============================
#     Initialize Clients
# ============================

credentials = service_account.Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE)
bigquery_client = bigquery.Client(project=PROJECT_ID, credentials=credentials)
firestore_client = firestore.Client(project=PROJECT_ID, credentials=credentials)

# ============================
#        Function Definitions
# ============================

def generate_timestamp():
    # Format timestamp as "YYYY-MM-DD HH:MM:SS.ffffff UTC" for BigQuery TIMESTAMP
    return datetime.now(ZoneInfo("UTC")).strftime("%Y-%m-%d %H:%M:%S.%f UTC")

def monitor_and_update_firestore_bigquery(interval=2):
    table_id = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
    
    while True:
        try:
            timestamp = generate_timestamp()
            data = {
                "Timestamp": timestamp,  # TIMESTAMP field expected by BQ (as string)
                "Machine": MACHINE_NAME,
            }

            try:
                ts = datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S.%f UTC")
                doc_ref.update({"PI_Timestamp": ts})
            except Exception as e:
                print(f"Firestore update error: {e}")

            try:
                # Specify the location since the table is in the US region
                errors = bigquery_client.insert_rows_json(table_id, [data], location="US")
                if errors:
                    print(f"BigQuery errors: {errors}")
            except Exception as e:
                print(f"BigQuery insert exception: {e}")
        except Exception as e:
            print(f"Monitoring error: {e}")

        time.sleep(interval)

# ============================
#         Main Execution
# ============================

if __name__ == "__main__":
    monitor_and_update_firestore_bigquery()
