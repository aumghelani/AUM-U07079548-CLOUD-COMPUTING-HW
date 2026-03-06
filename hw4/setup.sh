#!/bin/bash
# setup.sh - Provisions all HW4 infrastructure on GCP.
# Run from the hw4/ directory: bash setup.sh
#
# Prerequisites:
#   gcloud auth login
#   gcloud config set project <your-project-id>
#
# What this creates:
#   - Pub/Sub topic + subscription (forbidden-requests)
#   - Service account for VM1 (web server): hw4-service1-sa
#   - Service account for VM3 (reporter): hw4-service2-sa
#   - Static external IP for VM1
#   - VM1: web server (e2-micro, static IP, auto-start)
#   - VM2: client VM (e2-micro, for running http_client.py)
#   - VM3: service 2 reporter (e2-micro, auto-start)
#   - Firewall rule to allow TCP port 80 to VM1

set -e

# ── Dynamic project values ────────────────────────────────────────────────────
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# ── Configuration ─────────────────────────────────────────────────────────────
REGION="us-central1"
ZONE="us-central1-a"

BUCKET_NAME="aum-hw2-u07079548"    # existing HW2 bucket — NOT recreated
FILE_PREFIX="hw2/"
SCRIPTS_BUCKET="${BUCKET_NAME}"    # reuse same bucket for script uploads

TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

SA_SERVICE1="hw4-service1-sa"
SA_SERVICE2="hw4-service2-sa"

STATIC_IP_NAME="hw4-server-ip"
VM1_NAME="hw4-server-vm"
VM2_NAME="hw4-client-vm"
VM3_NAME="hw4-service2-vm"
FIREWALL_RULE="hw4-allow-http"

PORT="80"

echo "=== HW4 Setup ==="
echo "Project: ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "Region/Zone: ${REGION}/${ZONE}"

# ── Enable required APIs ──────────────────────────────────────────────────────
echo "[1/9] Enabling APIs ..."
gcloud services enable \
    compute.googleapis.com \
    pubsub.googleapis.com \
    logging.googleapis.com \
    storage.googleapis.com \
    --quiet

# ── Upload Python scripts to GCS so startup scripts can download them ─────────
echo "[2/9] Uploading scripts to GCS ..."
gcloud storage cp service1.py    "gs://${SCRIPTS_BUCKET}/hw4-scripts/service1.py"
gcloud storage cp service2.py    "gs://${SCRIPTS_BUCKET}/hw4-scripts/service2.py"
gcloud storage cp http_client.py "gs://${SCRIPTS_BUCKET}/hw4-scripts/http_client.py"

# ── Create Pub/Sub topic and subscription ─────────────────────────────────────
echo "[3/9] Creating Pub/Sub topic and subscription ..."
gcloud pubsub topics create "${TOPIC_ID}" --quiet 2>/dev/null || echo "  Topic already exists."
gcloud pubsub subscriptions create "${SUBSCRIPTION_ID}" \
    --topic="${TOPIC_ID}" \
    --quiet 2>/dev/null || echo "  Subscription already exists."

# ── Service account for VM1 (web server) ──────────────────────────────────────
echo "[4/9] Creating service accounts and IAM bindings ..."

gcloud iam service-accounts create "${SA_SERVICE1}" \
    --display-name="HW4 Service 1 Web Server" \
    --quiet 2>/dev/null || echo "  SA ${SA_SERVICE1} already exists."

SA1_EMAIL="${SA_SERVICE1}@${PROJECT_ID}.iam.gserviceaccount.com"

# Minimal permissions: read GCS objects, write logs, publish to Pub/Sub
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA1_EMAIL}" \
    --role="roles/storage.objectViewer" --quiet

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA1_EMAIL}" \
    --role="roles/logging.logWriter" --quiet

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA1_EMAIL}" \
    --role="roles/pubsub.publisher" --quiet

# Also needs to read the script from GCS (objectViewer already covers this)

# ── Service account for VM3 (reporter) ───────────────────────────────────────
gcloud iam service-accounts create "${SA_SERVICE2}" \
    --display-name="HW4 Service 2 Reporter" \
    --quiet 2>/dev/null || echo "  SA ${SA_SERVICE2} already exists."

SA2_EMAIL="${SA_SERVICE2}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA2_EMAIL}" \
    --role="roles/pubsub.subscriber" --quiet

# Needs to read the script from GCS
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA2_EMAIL}" \
    --role="roles/storage.objectViewer" --quiet

# ── Reserve static external IP for VM1 ───────────────────────────────────────
echo "[5/9] Reserving static IP ..."
gcloud compute addresses create "${STATIC_IP_NAME}" \
    --region="${REGION}" \
    --quiet 2>/dev/null || echo "  Static IP already exists."

STATIC_IP=$(gcloud compute addresses describe "${STATIC_IP_NAME}" \
    --region="${REGION}" \
    --format="value(address)")
echo "  Static IP: ${STATIC_IP}"

# ── Firewall rule: allow port 80 to VM1 ──────────────────────────────────────
echo "[6/9] Creating firewall rule ..."
gcloud compute firewall-rules create "${FIREWALL_RULE}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules="tcp:${PORT}" \
    --target-tags="hw4-http-server" \
    --quiet 2>/dev/null || echo "  Firewall rule already exists."

# ── Create VM1 (web server) ───────────────────────────────────────────────────
echo "[7/9] Creating VM1 (web server) ..."
gcloud compute instances create "${VM1_NAME}" \
    --zone="${ZONE}" \
    --machine-type="e2-micro" \
    --image-family="debian-12" \
    --image-project="debian-cloud" \
    --service-account="${SA1_EMAIL}" \
    --scopes="cloud-platform" \
    --address="${STATIC_IP}" \
    --tags="hw4-http-server" \
    --metadata="project-id=${PROJECT_ID},bucket-name=${BUCKET_NAME},topic-id=${TOPIC_ID},file-prefix=${FILE_PREFIX},port=${PORT},scripts-bucket=${SCRIPTS_BUCKET}" \
    --metadata-from-file="startup-script=startup_service1.sh" \
    --quiet

echo "  VM1 (${VM1_NAME}) created at ${STATIC_IP}:${PORT}"

# ── Create VM2 (client VM) ────────────────────────────────────────────────────
echo "[8/9] Creating VM2 (client VM) ..."
gcloud compute instances create "${VM2_NAME}" \
    --zone="${ZONE}" \
    --machine-type="e2-micro" \
    --image-family="debian-12" \
    --image-project="debian-cloud" \
    --service-account="${SA1_EMAIL}" \
    --scopes="cloud-platform" \
    --metadata="project-id=${PROJECT_ID},bucket-name=${BUCKET_NAME},scripts-bucket=${SCRIPTS_BUCKET},server-host=${STATIC_IP}" \
    --metadata-from-file="startup-script=startup_client.sh" \
    --quiet

# ── Create VM3 (service 2 reporter) ──────────────────────────────────────────
echo "[9/9] Creating VM3 (service 2 reporter) ..."
gcloud compute instances create "${VM3_NAME}" \
    --zone="${ZONE}" \
    --machine-type="e2-micro" \
    --image-family="debian-12" \
    --image-project="debian-cloud" \
    --service-account="${SA2_EMAIL}" \
    --scopes="cloud-platform" \
    --metadata="project-id=${PROJECT_ID},subscription-id=${SUBSCRIPTION_ID},scripts-bucket=${SCRIPTS_BUCKET}" \
    --metadata-from-file="startup-script=startup_service2.sh" \
    --quiet

echo ""
echo "=== Setup Complete ==="
echo "  Server (VM1) static IP : ${STATIC_IP}"
echo "  Server port             : ${PORT}"
echo "  Test with curl:"
echo "    curl http://${STATIC_IP}/${FILE_PREFIX}<filename>"
echo "    curl -X POST http://${STATIC_IP}/  # expect 501"
echo "    curl http://${STATIC_IP}/nonexistent.html  # expect 404"
echo ""
echo "  NOTE: VMs may take 1-2 minutes to finish installing dependencies."
