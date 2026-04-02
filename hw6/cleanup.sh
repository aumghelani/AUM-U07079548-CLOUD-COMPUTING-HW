#!/bin/bash
# cleanup.sh - Tears down HW6 infrastructure.
# Run from hw6/ directory: bash cleanup.sh
#
# This script:
#   - Deletes the ML VM (if still running)
#   - Stops Cloud SQL (does NOT delete — preserves HW5 data)
#   - Removes service account and IAM bindings
#   - Cleans up hw6-scripts from GCS

set -e

# ── HARDCODED project ID ─────────────────────────────────────────────────────
PROJECT_ID="u0709548-aum-hw1"

REGION="us-central1"
ZONE="us-central1-a"

BUCKET_NAME="aum-hw2-u07079548"

SQL_INSTANCE="hw5-mysql"
VM_NAME="hw6-ml-vm"
SA_NAME="hw6-ml-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== HW6 Cleanup ==="
echo "Project: ${PROJECT_ID}"

# ── Delete VM ────────────────────────────────────────────────────────────────
echo "[1/5] Deleting VM '${VM_NAME}' ..."
gcloud compute instances delete "${VM_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  VM not found, skipping."

# ── Stop Cloud SQL ───────────────────────────────────────────────────────────
echo "[2/5] Stopping Cloud SQL instance '${SQL_INSTANCE}' ..."
INSTANCE_STATUS=$(gcloud sql instances describe "${SQL_INSTANCE}" \
    --project="${PROJECT_ID}" --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

if [ "${INSTANCE_STATUS}" = "RUNNABLE" ]; then
    gcloud sql instances patch "${SQL_INSTANCE}" \
        --activation-policy=NEVER \
        --project="${PROJECT_ID}" --quiet
    echo "  Cloud SQL stopped."
elif [ "${INSTANCE_STATUS}" = "NOT_FOUND" ]; then
    echo "  Cloud SQL instance not found, skipping."
else
    echo "  Cloud SQL state=${INSTANCE_STATUS}, skipping."
fi

# ── Remove IAM bindings and SA ───────────────────────────────────────────────
echo "[3/5] Removing IAM bindings and service account ..."
for role in roles/cloudsql.client roles/storage.objectAdmin; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_EMAIL}" --role="${role}" \
        --quiet 2>/dev/null || true
done

gcloud iam service-accounts delete "${SA_EMAIL}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  SA not found."

# ── Remove hw6-scripts from GCS ─────────────────────────────────────────────
echo "[4/5] Removing hw6-scripts from GCS ..."
gcloud storage rm --recursive "gs://${BUCKET_NAME}/hw6-scripts/" 2>/dev/null \
    || echo "  hw6-scripts not found, skipping."

# ── Revoke application-default credentials if used ───────────────────────────
echo "[5/5] Revoking application-default credentials ..."
if gcloud auth application-default print-access-token &>/dev/null; then
    gcloud auth application-default revoke --quiet 2>/dev/null || true
fi

echo ""
echo "=== HW6 Cleanup Complete ==="
echo "  VM '${VM_NAME}' deleted."
echo "  Cloud SQL '${SQL_INSTANCE}' stopped (NOT deleted)."
echo "  HW6 model results remain at gs://${BUCKET_NAME}/hw6/"
