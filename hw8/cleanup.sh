#!/bin/bash
# cleanup.sh - Deletes all HW8 GCP resources.
# Run from the hw8/ directory: bash cleanup.sh

set -e

PROJECT_ID="u0709548-aum-hw1"
REGION="us-central1"
ZONE_A="us-central1-a"
ZONE_B="us-central1-b"

VM1_NAME="hw8-server-vm1"
VM2_NAME="hw8-server-vm2"

FIREWALL_HTTP="hw8-allow-http"
FIREWALL_HEALTH="hw8-allow-health-check"

HEALTH_CHECK="hw8-health-check"
TARGET_POOL="hw8-target-pool"
FWD_RULE="hw8-forwarding-rule"

SA_NAME="hw8-service1-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== HW8 Cleanup ==="
echo "Project: ${PROJECT_ID}"
echo ""

# ── Delete forwarding rule ────────────────────────────────────────────────────
echo "[1/7] Deleting forwarding rule ..."
gcloud compute forwarding-rules delete "${FWD_RULE}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Already deleted or not found."

# ── Delete target pool ────────────────────────────────────────────────────────
echo "[2/7] Deleting target pool ..."
gcloud compute target-pools delete "${TARGET_POOL}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Already deleted or not found."

# ── Delete health check ───────────────────────────────────────────────────────
echo "[3/7] Deleting health check ..."
gcloud compute http-health-checks delete "${HEALTH_CHECK}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Already deleted or not found."

# ── Delete VMs ────────────────────────────────────────────────────────────────
echo "[4/7] Deleting VMs ..."
gcloud compute instances delete "${VM1_NAME}" \
    --zone="${ZONE_A}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  VM1 already deleted or not found."

gcloud compute instances delete "${VM2_NAME}" \
    --zone="${ZONE_B}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  VM2 already deleted or not found."

# ── Delete firewall rules ────────────────────────────────────────────────────
echo "[5/7] Deleting firewall rules ..."
gcloud compute firewall-rules delete "${FIREWALL_HTTP}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Already deleted or not found."

gcloud compute firewall-rules delete "${FIREWALL_HEALTH}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Already deleted or not found."

# ── Delete service account ────────────────────────────────────────────────────
echo "[6/7] Deleting service account ..."
gcloud iam service-accounts delete "${SA_EMAIL}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || echo "  Already deleted or not found."

# ── Clean up GCS scripts ─────────────────────────────────────────────────────
echo "[7/7] Cleaning up GCS scripts ..."
gcloud storage rm "gs://aum-hw2-u07079548/hw8-scripts/" --recursive \
    --quiet 2>/dev/null || echo "  Already cleaned or not found."

echo ""
echo "=== HW8 Cleanup Complete ==="
