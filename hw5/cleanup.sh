#!/bin/bash
# cleanup.sh - Tears down HW5 infrastructure created by setup.sh.
# Run from the hw5/ directory: bash cleanup.sh
#
# IMPORTANT:
#   - Cloud SQL is STOPPED (not deleted) to preserve data.
#   - Static IPs are explicitly released.
#   - VMs and Pub/Sub resources are deleted.

set -e

# ── HARDCODED project ID (same as setup.sh) ───────────────────────────────────
PROJECT_ID="u0709548-aum-hw1"

REGION="us-central1"
ZONE="us-central1-a"

BUCKET_NAME="aum-hw2-u07079548"
SCRIPTS_BUCKET="${BUCKET_NAME}"

TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

SA_SERVICE1="hw5-service1-sa"
SA_SERVICE2="hw5-service2-sa"
CF_SA="hw5-cf-sa"
SA1_EMAIL="${SA_SERVICE1}@${PROJECT_ID}.iam.gserviceaccount.com"
SA2_EMAIL="${SA_SERVICE2}@${PROJECT_ID}.iam.gserviceaccount.com"
CF_SA_EMAIL="${CF_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

STATIC_IP_NAME="hw5-server-ip"
VM1_NAME="hw5-server-vm"
VM3_NAME="hw5-service2-vm"
FIREWALL_RULE="hw5-allow-http"

SQL_INSTANCE="hw5-mysql"
CF_NAME="stop-idle-db"

echo "=== HW5 Cleanup ==="
echo "Project: ${PROJECT_ID}"

# ── Delete VM instances ───────────────────────────────────────────────────────
echo "[1/9] Deleting VM instances ..."
for VM in "${VM1_NAME}" "${VM3_NAME}"; do
    gcloud compute instances delete "${VM}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
        || echo "  ${VM} not found, skipping."
done

# ── Release static IP ─────────────────────────────────────────────────────────
echo "[2/9] Releasing static IP ..."
gcloud compute addresses delete "${STATIC_IP_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  Static IP not found, skipping."

# ── Delete firewall rule ──────────────────────────────────────────────────────
echo "[3/9] Deleting firewall rule ..."
gcloud compute firewall-rules delete "${FIREWALL_RULE}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  Firewall rule not found, skipping."

# ── Delete Pub/Sub resources ──────────────────────────────────────────────────
echo "[4/9] Deleting Pub/Sub resources ..."
gcloud pubsub subscriptions delete "${SUBSCRIPTION_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Subscription not found."
gcloud pubsub topics delete "${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Topic not found."

# ── Delete Cloud Scheduler job ────────────────────────────────────────────────
echo "[5/9] Deleting Cloud Scheduler job ..."
gcloud scheduler jobs delete "${CF_NAME}-scheduler" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  Scheduler job not found, skipping."

# ── Delete Cloud Function ─────────────────────────────────────────────────────
echo "[6/9] Deleting Cloud Function ..."
gcloud functions delete "${CF_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --gen2 --quiet 2>/dev/null \
    || echo "  Cloud Function not found, skipping."

# ── STOP Cloud SQL (do NOT delete) ───────────────────────────────────────────
echo "[7/9] Stopping Cloud SQL instance '${SQL_INSTANCE}' (NOT deleting) ..."
INSTANCE_STATUS=$(gcloud sql instances describe "${SQL_INSTANCE}" \
    --project="${PROJECT_ID}" --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

if [ "${INSTANCE_STATUS}" = "RUNNABLE" ]; then
    gcloud sql instances patch "${SQL_INSTANCE}" \
        --activation-policy=NEVER \
        --project="${PROJECT_ID}" --quiet
    echo "  Cloud SQL instance stopped."
elif [ "${INSTANCE_STATUS}" = "NOT_FOUND" ]; then
    echo "  Cloud SQL instance not found, skipping."
else
    echo "  Cloud SQL instance state=${INSTANCE_STATUS}, skipping stop."
fi

# ── Remove IAM bindings and delete service accounts ──────────────────────────
echo "[8/9] Removing IAM bindings and service accounts ..."
for role in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher roles/cloudsql.client; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA1_EMAIL}" --role="${role}" \
        --quiet 2>/dev/null || true
done

for role in roles/pubsub.subscriber roles/storage.objectViewer; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA2_EMAIL}" --role="${role}" \
        --quiet 2>/dev/null || true
done

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CF_SA_EMAIL}" --role="roles/cloudsql.admin" \
    --quiet 2>/dev/null || true

gcloud iam service-accounts delete "${SA1_EMAIL}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  SA1 not found."
gcloud iam service-accounts delete "${SA2_EMAIL}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  SA2 not found."
gcloud iam service-accounts delete "${CF_SA_EMAIL}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  CF SA not found."

# ── Remove hw5-scripts from GCS (keep hw2 data files) ────────────────────────
echo "[9/9] Removing hw5-scripts from GCS ..."
gcloud storage rm --recursive "gs://${SCRIPTS_BUCKET}/hw5-scripts/" 2>/dev/null \
    || echo "  hw5-scripts not found in GCS, skipping."

# ── Revoke application-default credentials if used ───────────────────────────
if gcloud auth application-default print-access-token &>/dev/null; then
    gcloud auth application-default revoke --quiet 2>/dev/null || true
fi

echo ""
echo "=== HW5 Cleanup Complete ==="
echo "  Cloud SQL '${SQL_INSTANCE}' has been STOPPED (not deleted)."
echo "  HW2 bucket data files were NOT deleted."
