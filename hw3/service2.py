"""
Service 2 – runs on your LOCAL LAPTOP.
Subscribes to a Pub/Sub topic, prints forbidden-request alerts,
and appends them to a log file in a dedicated GCS directory.

Authentication: Service Account Impersonation.
  - Uses your personal Google account (gcloud auth login) as the SOURCE credential.
  - Impersonates the hw3-service-668 service account to get a short-lived token.
  - No key file is stored on disk — credentials are ephemeral and auto-refreshed.
  - This is safer than a JSON key and more scoped than application-default login.

How it works:
  1. google.auth.default() picks up your personal gcloud login token.
  2. impersonated_credentials.Credentials asks GCP's IAM to issue a short-lived
     access token valid only for the target service account's permissions.
  3. All SDK clients are initialized with these impersonated credentials.

Prerequisites:
  - Run: gcloud auth login
  - Your personal account must have roles/iam.serviceAccountTokenCreator
    on hw3-service-668@u0709548-aum-hw1.iam.gserviceaccount.com
"""

import json
from datetime import datetime, timezone

import google.auth
from google.auth import impersonated_credentials
from google.cloud import pubsub_v1, storage

# ── Configuration ─────────────────────────────────────────────────────────────
GCP_PROJECT_ID      = "U0709548-AUM-HW1"
SERVICE_ACCOUNT     = "hw3-service-668@u0709548-aum-hw1.iam.gserviceaccount.com"
SUBSCRIPTION_ID     = "forbidden-requests-sub"
BUCKET_NAME         = "aum-hw2-u07079548"
LOG_PREFIX          = "forbidden-logs/"
LOG_BLOB_NAME       = f"{LOG_PREFIX}forbidden_requests.log"

# ── Build impersonated credentials ────────────────────────────────────────────
# Step 1: get your personal gcloud credentials (from `gcloud auth login`)
source_credentials, _ = google.auth.default()

# Step 2: impersonate the service account — issues a short-lived token
impersonated_creds = impersonated_credentials.Credentials(
    source_credentials = source_credentials,
    target_principal   = SERVICE_ACCOUNT,
    target_scopes      = ["https://www.googleapis.com/auth/cloud-platform"],
)

# ── GCS client using impersonated credentials ─────────────────────────────────
gcs_client = storage.Client(project=GCP_PROJECT_ID, credentials=impersonated_creds)


def append_to_gcs(message_text: str):
    """Download existing log, append new line, upload back."""
    bucket = gcs_client.bucket(BUCKET_NAME)
    blob   = bucket.blob(LOG_BLOB_NAME)

    existing = ""
    if blob.exists():
        existing = blob.download_as_text()

    updated = existing + message_text + "\n"
    blob.upload_from_string(updated, content_type="text/plain")


def callback(message: pubsub_v1.subscriber.message.Message):
    """Called for every Pub/Sub message received."""
    try:
        data    = json.loads(message.data.decode("utf-8"))
        country = data.get("country", "unknown")
        file_r  = data.get("file_requested", "(none)")
        remote  = data.get("remote_addr", "unknown")
        ts      = datetime.now(timezone.utc).isoformat()

        log_line = (
            f"[{ts}] FORBIDDEN REQUEST — "
            f"country={country}, file={file_r}, remote_addr={remote}"
        )

        # Print to stdout (standard output of this local process)
        print(log_line)

        # Append to GCS log file in the forbidden-logs/ directory
        append_to_gcs(log_line)

    except Exception as exc:
        print(f"[ERROR] Failed to process message: {exc}")
    finally:
        message.ack()


def main():
    # Pub/Sub subscriber also uses impersonated credentials
    subscriber        = pubsub_v1.SubscriberClient(credentials=impersonated_creds)
    subscription_path = subscriber.subscription_path(GCP_PROJECT_ID, SUBSCRIPTION_ID)

    print(f"[Service 2] Authenticated via impersonation as: {SERVICE_ACCOUNT}")
    print(f"[Service 2] Listening on {subscription_path} …")
    streaming_pull = subscriber.subscribe(subscription_path, callback=callback)

    try:
        streaming_pull.result()   # blocks forever
    except KeyboardInterrupt:
        streaming_pull.cancel()
        streaming_pull.result()
        print("[Service 2] Stopped.")


if __name__ == "__main__":
    main()
