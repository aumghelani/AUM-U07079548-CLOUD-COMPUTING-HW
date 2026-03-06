#!/bin/bash
# cleanup.sh - Tears down ALL infrastructure created by setup.sh.
# Run from the hw4/ directory: bash cleanup.sh
#
# WARNING: This deletes VMs, service accounts, Pub/Sub resources,
#          firewall rules, static IPs, and GCS script files.
#          It does NOT delete the HW2 bucket or its data files.

set -e

PROJECT_ID=$(gcloud config get-value project)

REGION="us-central1"
ZONE="us-central1-a"

BUCKET_NAME="aum-hw2-u07079548"
SCRIPTS_BUCKET="${BUCKET_NAME}"

TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

SA_SERVICE1="hw4-service1-sa"
SA_SERVICE2="hw4-service2-sa"
SA1_EMAIL="${SA_SERVICE1}@${PROJECT_ID}.iam.gserviceaccount.com"
SA2_EMAIL="${SA_SERVICE2}@${PROJECT_ID}.iam.gserviceaccount.com"

STATIC_IP_NAME="hw4-server-ip"
VM1_NAME="hw4-server-vm"
VM2_NAME="hw4-client-vm"
VM3_NAME="hw4-service2-vm"
FIREWALL_RULE="hw4-allow-http"

echo "=== HW4 Cleanup ==="
echo "Project: ${PROJECT_ID}"

# ── Delete VM instances ───────────────────────────────────────────────────────
echo "[1/7] Deleting VM instances ..."
gcloud compute instances delete "${VM1_NAME}" --zone="${ZONE}" --quiet 2>/dev/null \
    || echo "  VM1 not found, skipping."
gcloud compute instances delete "${VM2_NAME}" --zone="${ZONE}" --quiet 2>/dev/null \
    || echo "  VM2 not found, skipping."
gcloud compute instances delete "${VM3_NAME}" --zone="${ZONE}" --quiet 2>/dev/null \
    || echo "  VM3 not found, skipping."

# ── Release static IP ─────────────────────────────────────────────────────────
echo "[2/7] Releasing static IP ..."
gcloud compute addresses delete "${STATIC_IP_NAME}" \
    --region="${REGION}" --quiet 2>/dev/null \
    || echo "  Static IP not found, skipping."

# ── Delete firewall rule ──────────────────────────────────────────────────────
echo "[3/7] Deleting firewall rule ..."
gcloud compute firewall-rules delete "${FIREWALL_RULE}" --quiet 2>/dev/null \
    || echo "  Firewall rule not found, skipping."

# ── Delete Pub/Sub subscription and topic ────────────────────────────────────
echo "[4/7] Deleting Pub/Sub resources ..."
gcloud pubsub subscriptions delete "${SUBSCRIPTION_ID}" --quiet 2>/dev/null \
    || echo "  Subscription not found, skipping."
gcloud pubsub topics delete "${TOPIC_ID}" --quiet 2>/dev/null \
    || echo "  Topic not found, skipping."

# ── Remove IAM bindings and delete service accounts ──────────────────────────
echo "[5/7] Removing IAM bindings for SA1 ..."
for role in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA1_EMAIL}" \
        --role="${role}" --quiet 2>/dev/null || true
done

echo "[6/7] Removing IAM bindings for SA2 ..."
for role in roles/pubsub.subscriber roles/storage.objectViewer; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA2_EMAIL}" \
        --role="${role}" --quiet 2>/dev/null || true
done

gcloud iam service-accounts delete "${SA1_EMAIL}" --quiet 2>/dev/null \
    || echo "  SA1 not found, skipping."
gcloud iam service-accounts delete "${SA2_EMAIL}" --quiet 2>/dev/null \
    || echo "  SA2 not found, skipping."

# ── Delete uploaded scripts from GCS (NOT the hw2 data files) ────────────────
echo "[7/7] Removing hw4-scripts from GCS ..."
gcloud storage rm --recursive "gs://${SCRIPTS_BUCKET}/hw4-scripts/" 2>/dev/null \
    || echo "  hw4-scripts not found in GCS, skipping."

echo ""
echo "=== Cleanup Complete ==="
echo "  NOTE: The HW2 bucket (gs://${BUCKET_NAME}) and its data files were NOT deleted."
