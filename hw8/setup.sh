#!/bin/bash
# setup.sh - Provisions all HW8 infrastructure on GCP.
# Creates 2 VMs in different zones behind a Network Load Balancer.
# Run from the hw8/ directory: bash setup.sh
#
# What this creates:
#   - Pub/Sub topic + subscription (reuse from HW4)
#   - Service account for web server VMs
#   - 2 VMs running service1.py in different zones (same region)
#   - Network Load Balancer (TCP) with health check
#   - Firewall rules for HTTP traffic and health checks

set -e

# ── Hardcoded project values ─────────────────────────────────────────────────
PROJECT_ID="u0709548-aum-hw1"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

# ── Configuration ─────────────────────────────────────────────────────────────
REGION="us-central1"
ZONE_A="us-central1-a"
ZONE_B="us-central1-b"

BUCKET_NAME="aum-hw2-u07079548"
FILE_PREFIX="hw2/"
SCRIPTS_BUCKET="${BUCKET_NAME}"

TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

SA_NAME="hw8-service1-sa"

VM1_NAME="hw8-server-vm1"
VM2_NAME="hw8-server-vm2"

FIREWALL_HTTP="hw8-allow-http"
FIREWALL_HEALTH="hw8-allow-health-check"

# Load balancer resources
HEALTH_CHECK="hw8-health-check"
TARGET_POOL="hw8-target-pool"
FWD_RULE="hw8-forwarding-rule"

PORT="80"

echo "=== HW8 Setup ==="
echo "Project: ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "Region: ${REGION}"
echo "Zones: ${ZONE_A}, ${ZONE_B}"

# ── Enable required APIs ──────────────────────────────────────────────────────
echo "[1/10] Enabling APIs ..."
gcloud services enable \
    compute.googleapis.com \
    pubsub.googleapis.com \
    logging.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}" \
    --quiet

# ── Upload scripts to GCS ────────────────────────────────────────────────────
echo "[2/10] Uploading scripts to GCS ..."
gcloud storage cp service1.py "gs://${SCRIPTS_BUCKET}/hw8-scripts/service1.py"

# ── Create Pub/Sub topic and subscription (if not existing from HW4) ─────────
echo "[3/10] Ensuring Pub/Sub topic and subscription exist ..."
gcloud pubsub topics create "${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Topic already exists."
gcloud pubsub subscriptions create "${SUBSCRIPTION_ID}" \
    --topic="${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Subscription already exists."

# ── Service account ───────────────────────────────────────────────────────────
echo "[4/10] Creating service account and IAM bindings ..."
gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="HW8 Service 1 Web Server" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  SA ${SA_NAME} already exists."

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

for ROLE in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="${ROLE}" --quiet > /dev/null
done

# ── Firewall rules ────────────────────────────────────────────────────────────
echo "[5/10] Creating firewall rules ..."
# Allow HTTP from anywhere to tagged VMs
gcloud compute firewall-rules create "${FIREWALL_HTTP}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules="tcp:${PORT}" \
    --target-tags="hw8-http-server" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Firewall rule ${FIREWALL_HTTP} already exists."

# Allow health check probes from Google's health check IP ranges
gcloud compute firewall-rules create "${FIREWALL_HEALTH}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules="tcp:${PORT}" \
    --source-ranges="35.191.0.0/16,209.85.152.0/22,209.85.204.0/22,130.211.0.0/22" \
    --target-tags="hw8-http-server" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Firewall rule ${FIREWALL_HEALTH} already exists."

# ── Create VM1 in Zone A ─────────────────────────────────────────────────────
echo "[6/10] Creating VM1 (${VM1_NAME}) in ${ZONE_A} ..."
if gcloud compute instances describe "${VM1_NAME}" --zone="${ZONE_A}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
    echo "  VM1 already exists, skipping creation."
else
    gcloud compute instances create "${VM1_NAME}" \
        --zone="${ZONE_A}" \
        --machine-type="e2-micro" \
        --image-family="debian-12" \
        --image-project="debian-cloud" \
        --service-account="${SA_EMAIL}" \
        --scopes="cloud-platform" \
        --tags="hw8-http-server" \
        --metadata="project-id=${PROJECT_ID},bucket-name=${BUCKET_NAME},topic-id=${TOPIC_ID},file-prefix=${FILE_PREFIX},port=${PORT},scripts-bucket=${SCRIPTS_BUCKET}" \
        --metadata-from-file="startup-script=startup_service1.sh" \
        --project="${PROJECT_ID}" \
        --quiet
fi

# ── Create VM2 in Zone B ─────────────────────────────────────────────────────
echo "[7/10] Creating VM2 (${VM2_NAME}) in ${ZONE_B} ..."
if gcloud compute instances describe "${VM2_NAME}" --zone="${ZONE_B}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
    echo "  VM2 already exists, skipping creation."
else
    gcloud compute instances create "${VM2_NAME}" \
        --zone="${ZONE_B}" \
        --machine-type="e2-micro" \
        --image-family="debian-12" \
        --image-project="debian-cloud" \
        --service-account="${SA_EMAIL}" \
        --scopes="cloud-platform" \
        --tags="hw8-http-server" \
        --metadata="project-id=${PROJECT_ID},bucket-name=${BUCKET_NAME},topic-id=${TOPIC_ID},file-prefix=${FILE_PREFIX},port=${PORT},scripts-bucket=${SCRIPTS_BUCKET}" \
        --metadata-from-file="startup-script=startup_service1.sh" \
        --project="${PROJECT_ID}" \
        --quiet
fi

# ── Network Load Balancer Setup ───────────────────────────────────────────────

# Create HTTP health check (checks GET /health on port 80)
echo "[8/10] Creating health check ..."
# NOTE: --request-path uses "//health" (double slash) on purpose.
# Git Bash on Windows (MSYS) rewrites a bare leading "/" into a Windows
# path ("C:/Program Files/Git/..."). Prefixing with "//" tells MSYS to
# collapse it to a single "/" and pass it through literally, so gcloud
# ultimately sees "/health". On Linux/macOS MSYS rules don't apply and
# "//health" behaves identically to "/health".
if gcloud compute http-health-checks describe "${HEALTH_CHECK}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
    echo "  Health check already exists."
else
    gcloud compute http-health-checks create "${HEALTH_CHECK}" \
        --port="${PORT}" \
        --request-path=//health \
        --check-interval="5s" \
        --timeout="3s" \
        --healthy-threshold="2" \
        --unhealthy-threshold="3" \
        --project="${PROJECT_ID}" \
        --quiet
fi

# Create target pool with health check
echo "[9/10] Creating target pool and adding instances ..."
gcloud compute target-pools create "${TARGET_POOL}" \
    --region="${REGION}" \
    --http-health-check="${HEALTH_CHECK}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Target pool already exists."

# Add both VMs to the target pool
gcloud compute target-pools add-instances "${TARGET_POOL}" \
    --instances="${VM1_NAME}" \
    --instances-zone="${ZONE_A}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  VM1 already in target pool."

gcloud compute target-pools add-instances "${TARGET_POOL}" \
    --instances="${VM2_NAME}" \
    --instances-zone="${ZONE_B}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  VM2 already in target pool."

# Create forwarding rule (the actual load balancer external IP)
echo "[10/10] Creating forwarding rule (load balancer IP) ..."
gcloud compute forwarding-rules create "${FWD_RULE}" \
    --region="${REGION}" \
    --ports="${PORT}" \
    --target-pool="${TARGET_POOL}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Forwarding rule already exists."

# ── Get the Load Balancer IP ──────────────────────────────────────────────────
LB_IP=$(gcloud compute forwarding-rules describe "${FWD_RULE}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="value(IPAddress)")

# ── Get VM external IPs for reference ─────────────────────────────────────────
VM1_IP=$(gcloud compute instances describe "${VM1_NAME}" \
    --zone="${ZONE_A}" \
    --project="${PROJECT_ID}" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

VM2_IP=$(gcloud compute instances describe "${VM2_NAME}" \
    --zone="${ZONE_B}" \
    --project="${PROJECT_ID}" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

# ── Grant grader access ───────────────────────────────────────────────────────
echo ""
echo "Granting grader access ..."
for EMAIL in adrishd@bu.edu bpri1504@bu.edu; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/editor" --quiet > /dev/null 2>&1 || true
done

echo ""
echo "================================================================"
echo "=== HW8 Setup Complete ==="
echo "================================================================"
echo ""
echo "  Load Balancer IP : ${LB_IP}"
echo "  VM1 (${ZONE_A})  : ${VM1_IP}"
echo "  VM2 (${ZONE_B})  : ${VM2_IP}"
echo ""
echo "  NOTE: VMs need 2-3 minutes to finish startup (installing packages)."
echo ""
echo "  Test individual VMs:"
echo "    curl -s -D - http://${VM1_IP}/0.html 2>/dev/null | head -20"
echo "    curl -s -D - http://${VM2_IP}/0.html 2>/dev/null | head -20"
echo ""
echo "  Test load balancer:"
echo "    curl -s -D - http://${LB_IP}/0.html 2>/dev/null | head -20"
echo ""
echo "  Run the client (1 request/second for 60s):"
echo "    python3 client.py ${LB_IP} 60"
echo ""
echo "  Kill server on VM1 (for failover test):"
echo "    gcloud compute ssh ${VM1_NAME} --zone=${ZONE_A} --command='sudo systemctl stop service1'"
echo ""
echo "  Restart server on VM1:"
echo "    gcloud compute ssh ${VM1_NAME} --zone=${ZONE_A} --command='sudo systemctl start service1'"
echo "================================================================"
