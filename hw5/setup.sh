#!/bin/bash
# setup.sh - Provisions all HW5 infrastructure on GCP.
# Run from the hw5/ directory: bash setup.sh
#
# Prerequisites:
#   gcloud auth login
#   (Project ID is hardcoded below — do NOT change to gcloud config get-value project)
#
# What this creates / starts:
#   - Cloud SQL MySQL instance (hw5-mysql) — created if missing, started if stopped
#   - Pub/Sub topic + subscription (reused from HW4 pattern)
#   - Service accounts with correct IAM roles
#   - Static external IP for VM1
#   - VM1: web server (e2-standard-2, handles 2 concurrent clients)
#   - VM2a, VM2b: two client VMs
#   - VM3: service 2 forbidden-country reporter
#   - Cloud Function: stop_idle_db (hourly scheduler)
#   - Firewall rule to allow TCP port 80 to VM1

set -e
export DEBIAN_FRONTEND=noninteractive

# ── HARDCODED project ID (required by grader — do NOT use gcloud config get-value) ──
PROJECT_ID="u0709548-aum-hw1"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")

# ── Configuration ─────────────────────────────────────────────────────────────
REGION="us-central1"
ZONE="us-central1-a"

BUCKET_NAME="aum-hw2-u07079548"
FILE_PREFIX="hw2/"
SCRIPTS_BUCKET="${BUCKET_NAME}"

TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

SA_SERVICE1="hw5-service1-sa"
SA_SERVICE2="hw5-service2-sa"

STATIC_IP_NAME="hw5-server-ip"
VM1_NAME="hw5-server-vm"
VM3_NAME="hw5-service2-vm"
FIREWALL_RULE="hw5-allow-http"

PORT="80"

# Cloud SQL
SQL_INSTANCE="hw5-mysql"
SQL_REGION="${REGION}"
SQL_TIER="db-n1-standard-1"
DB_NAME="hw5db"
DB_USER="hw5user"
# Generate a random password if not already set
DB_PASSWORD="aumcloudhw123"

# Cloud Function
CF_NAME="stop-idle-db"
CF_SA="hw5-cf-sa"

echo "=== HW5 Setup ==="
echo "Project : ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "Region  : ${REGION} / ${ZONE}"

# ── Enable required APIs ──────────────────────────────────────────────────────
echo "[1/10] Enabling APIs ..."
gcloud services enable \
    compute.googleapis.com \
    pubsub.googleapis.com \
    logging.googleapis.com \
    storage.googleapis.com \
    sqladmin.googleapis.com \
    cloudfunctions.googleapis.com \
    cloudscheduler.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    --project="${PROJECT_ID}" \
    --quiet

# ── Upload scripts to GCS ─────────────────────────────────────────────────────
echo "[2/10] Uploading scripts to GCS ..."
gcloud storage cp service1.py       "gs://${SCRIPTS_BUCKET}/hw5-scripts/service1.py"
gcloud storage cp service2.py       "gs://${SCRIPTS_BUCKET}/hw5-scripts/service2.py"
gcloud storage cp setup_schema.py   "gs://${SCRIPTS_BUCKET}/hw5-scripts/setup_schema.py"

# ── Cloud SQL: create or start ────────────────────────────────────────────────
echo "[3/10] Configuring Cloud SQL instance '${SQL_INSTANCE}' ..."

setup_cloud_sql() {
    # Check if instance already exists
    INSTANCE_STATUS=$(gcloud sql instances describe "${SQL_INSTANCE}" \
        --project="${PROJECT_ID}" \
        --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

    if [ "${INSTANCE_STATUS}" = "NOT_FOUND" ]; then
        echo "  Creating Cloud SQL instance (this takes ~5 min) ..."
        gcloud sql instances create "${SQL_INSTANCE}" \
            --project="${PROJECT_ID}" \
            --database-version=MYSQL_8_0 \
            --tier="${SQL_TIER}" \
            --region="${SQL_REGION}" \
            --storage-type=SSD \
            --storage-size=10GB \
            --no-backup \
            --quiet

        # Create database user
        gcloud sql users create "${DB_USER}" \
            --instance="${SQL_INSTANCE}" \
            --project="${PROJECT_ID}" \
            --password="${DB_PASSWORD}" \
            --quiet

        # Create database
        gcloud sql databases create "${DB_NAME}" \
            --instance="${SQL_INSTANCE}" \
            --project="${PROJECT_ID}" \
            --quiet

        echo "  Cloud SQL instance created."
        # Schema will be set up by startup.sh on VM1 via the proxy

    elif [ "${INSTANCE_STATUS}" = "STOPPED" ]; then
        echo "  Instance exists but is STOPPED — starting it ..."
        gcloud sql instances patch "${SQL_INSTANCE}" \
            --project="${PROJECT_ID}" \
            --activation-policy=ALWAYS \
            --quiet
        echo "  Waiting for instance to start ..."
        for i in $(seq 1 30); do
            ST=$(gcloud sql instances describe "${SQL_INSTANCE}" \
                --project="${PROJECT_ID}" \
                --format="value(state)" 2>/dev/null || echo "UNKNOWN")
            echo "    state=${ST} (attempt ${i}/30)"
            [ "${ST}" = "RUNNABLE" ] && break
            sleep 10
        done
    else
        echo "  Instance state: ${INSTANCE_STATUS} — nothing to do."
    fi
}

setup_cloud_sql

# Retrieve Cloud SQL connection name and public IP
DB_CONN_NAME=$(gcloud sql instances describe "${SQL_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --format="value(connectionName)")
DB_PUBLIC_IP=$(gcloud sql instances describe "${SQL_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --format="value(ipAddresses[0].ipAddress)")
echo "  DB_CONN_NAME=${DB_CONN_NAME}"
echo "  DB_PUBLIC_IP=${DB_PUBLIC_IP}"

# ── Allow current machine's IP to access Cloud SQL via public IP ──────────────
MY_IP=$(curl -sf https://checkip.amazonaws.com || curl -sf https://api.ipify.org)
echo "  Authorizing setup machine IP ${MY_IP} for Cloud SQL ..."
gcloud sql instances patch "${SQL_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --authorized-networks="${MY_IP}/32" \
    --quiet

# ── Run schema initialization from setup.sh (as required by TA instructions) ──
echo "  Running schema setup from setup.sh ..."
# Use the python that owns pip3 (C:/Python313 on this machine)
PY=$(pip3 -V | grep -oP '\(.*?\)' | tr -d '()' | awk '{print $NF}' || echo "")
if [ -z "${PY}" ] || [ ! -f "${PY}" ]; then
    PY="/c/Python313/python.exe"
fi
echo "  Using Python: ${PY}"
"${PY}" -m pip install --quiet pymysql cryptography
DB_HOST="${DB_PUBLIC_IP}" DB_PORT=3306 DB_NAME="${DB_NAME}" \
DB_USER="${DB_USER}" DB_PASSWORD="${DB_PASSWORD}" \
"${PY}" setup_schema.py

# ── Pub/Sub ───────────────────────────────────────────────────────────────────
echo "[4/10] Creating Pub/Sub topic and subscription ..."
gcloud pubsub topics create "${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Topic already exists."
gcloud pubsub subscriptions create "${SUBSCRIPTION_ID}" \
    --topic="${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Subscription already exists."

# ── Service accounts ──────────────────────────────────────────────────────────
echo "[5/10] Creating service accounts and IAM bindings ..."

# SA for VM1 (web server)
gcloud iam service-accounts create "${SA_SERVICE1}" \
    --display-name="HW5 Service 1 Web Server" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  SA ${SA_SERVICE1} already exists."
SA1_EMAIL="${SA_SERVICE1}@${PROJECT_ID}.iam.gserviceaccount.com"

for role in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher roles/cloudsql.client; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA1_EMAIL}" --role="${role}" --quiet
done

# SA for VM3 (reporter)
gcloud iam service-accounts create "${SA_SERVICE2}" \
    --display-name="HW5 Service 2 Reporter" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  SA ${SA_SERVICE2} already exists."
SA2_EMAIL="${SA_SERVICE2}@${PROJECT_ID}.iam.gserviceaccount.com"

for role in roles/pubsub.subscriber roles/storage.objectViewer; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA2_EMAIL}" --role="${role}" --quiet
done

# SA for Cloud Function
gcloud iam service-accounts create "${CF_SA}" \
    --display-name="HW5 Cloud Function SA" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  SA ${CF_SA} already exists."
CF_SA_EMAIL="${CF_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CF_SA_EMAIL}" \
    --role="roles/cloudsql.admin" --quiet

# ── Static IP ─────────────────────────────────────────────────────────────────
echo "[6/11] Reserving static IP ..."
gcloud compute addresses create "${STATIC_IP_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Static IP already exists."

STATIC_IP=$(gcloud compute addresses describe "${STATIC_IP_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(address)")
echo "  Static IP: ${STATIC_IP}"

# ── Firewall rule ─────────────────────────────────────────────────────────────
echo "[7/11] Creating firewall rule ..."
gcloud compute firewall-rules create "${FIREWALL_RULE}" \
    --direction=INGRESS --action=ALLOW \
    --rules="tcp:${PORT}" \
    --target-tags="hw5-http-server" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Firewall rule already exists."

# ── VM1: web server (e2-standard-2 to handle 2 concurrent clients) ────────────
echo "[8/10] Creating VM1 (web server) ..."
gcloud compute instances create "${VM1_NAME}" \
    --zone="${ZONE}" \
    --machine-type="e2-standard-2" \
    --image-family="debian-12" \
    --image-project="debian-cloud" \
    --service-account="${SA1_EMAIL}" \
    --scopes="cloud-platform" \
    --address="${STATIC_IP}" \
    --tags="hw5-http-server" \
    --project="${PROJECT_ID}" \
    --metadata="project-id=${PROJECT_ID},bucket-name=${BUCKET_NAME},topic-id=${TOPIC_ID},file-prefix=${FILE_PREFIX},port=${PORT},scripts-bucket=${SCRIPTS_BUCKET},db-name=${DB_NAME},db-user=${DB_USER},db-password=${DB_PASSWORD},db-conn-name=${DB_CONN_NAME}" \
    --metadata-from-file="startup-script=startup.sh" \
    --quiet
echo "  VM1 (${VM1_NAME}) created at ${STATIC_IP}:${PORT}"

# ── VM3: service 2 forbidden-country reporter ─────────────────────────────────
# NOTE: The http-client.exe runs from your local Windows laptop (not a VM).
# Run 2 concurrent clients with the same seed:
#   http-client.exe -d <STATIC_IP> -b none -w none -n 50000 -i 20000 -p 80 -r 42
echo "[9/10] Creating VM3 (service 2 reporter) ..."
gcloud compute instances create "${VM3_NAME}" \
    --zone="${ZONE}" \
    --machine-type="e2-micro" \
    --image-family="debian-12" \
    --image-project="debian-cloud" \
    --service-account="${SA2_EMAIL}" \
    --scopes="cloud-platform" \
    --project="${PROJECT_ID}" \
    --metadata="project-id=${PROJECT_ID},subscription-id=${SUBSCRIPTION_ID},scripts-bucket=${SCRIPTS_BUCKET}" \
    --metadata-from-file="startup-script=startup_service2.sh" \
    --quiet

# ── Cloud Function: stop_idle_db + Cloud Scheduler (every 1 hour) ─────────────
echo "[10/10] Deploying Cloud Function 'stop_idle_db' ..."

gcloud functions deploy "${CF_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --runtime=python311 \
    --source=./stop_db_function \
    --entry-point=stop_idle_db \
    --trigger-http \
    --service-account="${CF_SA_EMAIL}" \
    --set-env-vars="PROJECT_ID=${PROJECT_ID},INSTANCE_ID=${SQL_INSTANCE}" \
    --no-allow-unauthenticated \
    --gen2 \
    --quiet

CF_URL=$(gcloud functions describe "${CF_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format="value(serviceConfig.uri)" 2>/dev/null || \
    gcloud functions describe "${CF_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format="value(httpsTrigger.url)")

# Cloud Scheduler job — runs every hour
gcloud scheduler jobs create http "${CF_NAME}-scheduler" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --schedule="0 * * * *" \
    --uri="${CF_URL}" \
    --oidc-service-account-email="${CF_SA_EMAIL}" \
    --quiet 2>/dev/null || echo "  Scheduler job already exists."

echo ""
echo "=== HW5 Setup Complete ==="
echo "  Server (VM1) static IP   : ${STATIC_IP}"
echo "  Server port              : ${PORT}"
echo "  Cloud SQL instance       : ${SQL_INSTANCE} (${DB_CONN_NAME})"
echo ""
echo "  NOTE: VM1 may take 2-3 minutes to finish installing dependencies."
echo "  Test with:"
echo "    curl http://${STATIC_IP}/${FILE_PREFIX}<filename>"
echo ""
echo "  To run the 2 concurrent clients (from your local Windows laptop):"
echo "  Open 2 terminals and run the same command in both simultaneously:"
echo "    ./http-client.exe -d ${STATIC_IP} -b ${BUCKET_NAME} -w ${FILE_PREFIX%/} -n 50000 -i 20000 -p 80 -r 42"
echo ""
echo "  After clients finish, run stats:"
echo "    DB_HOST=${DB_PUBLIC_IP} DB_NAME=${DB_NAME} DB_USER=${DB_USER} DB_PASSWORD=${DB_PASSWORD} python3 query_stats.py"
