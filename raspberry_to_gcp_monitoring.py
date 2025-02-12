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
    local_tz = ZoneInfo("UTC")
    now_utc = datetime.now(local_tz)
    return now_utc.isoformat()

def monitor_and_update_firestore_bigquery(interval=2):
    previous_status = None
    table_id = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"
    doc_ref = firestore_client.collection(FIRESTORE_COLLECTION).document(MACHINE_NAME)
    timestamp = generate_timestamp()
    while True:
        try:
            data = {
                "Timestamp": timestamp,
                "Machine": MACHINE_NAME,
            }

            try:
                doc_ref.update({"PI_Timestamp": timestamp})
            except Exception as e:
                print(f"Firestore update error: {e}")

            try:
                errors = bigquery_client.insert_rows_json(table_id, [data])
                if errors:
                    print(f"BigQuery errors: {errors}")
            except Exception as e:
                print(f"BigQuery insert exception: {e}")

            previous_status = data["Status"]
        except Exception as e:
            print(f"Monitoring error: {e}")

        time.sleep(interval)

# ============================
#         Main Execution
# ============================

if __name__ == "__main__":
    monitor_and_update_firestore_bigquery()
