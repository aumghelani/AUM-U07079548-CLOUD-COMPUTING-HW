#!/bin/bash
# setup.sh - HW6 Setup Script
# Provisions infrastructure, runs ML models on a VM, then cleans up.
#
# This script:
#   1. Enables required APIs
#   2. Uploads scripts to GCS
#   3. Starts Cloud SQL (hw5-mysql) if stopped
#   4. Creates service account + IAM bindings
#   5. Creates ML VM with startup script
#   6. Waits for models to complete (polls for DONE marker in GCS)
#   7. Prints model output from GCS
#   8. Deletes the VM
#   9. Stops Cloud SQL
#
# Run from hw6/ directory: bash setup.sh

set -e
export DEBIAN_FRONTEND=noninteractive

# ── HARDCODED project ID ─────────────────────────────────────────────────────
PROJECT_ID="u0709548-aum-hw1"

REGION="us-central1"
ZONE="us-central1-a"

BUCKET_NAME="aum-hw2-u07079548"

# Cloud SQL (reuse from HW5)
SQL_INSTANCE="hw5-mysql"
DB_NAME="hw5db"
DB_USER="hw5user"
DB_PASSWORD="aumcloudhw123"

# HW6 VM
VM_NAME="hw6-ml-vm"
SA_NAME="hw6-ml-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== HW6 Setup ==="
echo "Project : ${PROJECT_ID}"
echo "Region  : ${REGION} / ${ZONE}"

# ── [1/9] Enable APIs ────────────────────────────────────────────────────────
echo "[1/9] Enabling APIs ..."
gcloud services enable \
    compute.googleapis.com \
    sqladmin.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}" \
    --quiet

# ── [2/9] Upload scripts to GCS ─────────────────────────────────────────────
echo "[2/9] Uploading HW6 scripts to GCS ..."
gcloud storage cp normalize_schema.py "gs://${BUCKET_NAME}/hw6-scripts/normalize_schema.py"
gcloud storage cp models.py           "gs://${BUCKET_NAME}/hw6-scripts/models.py"

# ── [3/9] Start Cloud SQL ────────────────────────────────────────────────────
echo "[3/9] Starting Cloud SQL instance '${SQL_INSTANCE}' ..."

INSTANCE_STATUS=$(gcloud sql instances describe "${SQL_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --format="value(state)" 2>/dev/null || echo "NOT_FOUND")

if [ "${INSTANCE_STATUS}" = "NOT_FOUND" ]; then
    echo "  ERROR: Cloud SQL instance '${SQL_INSTANCE}' not found!"
    echo "  Please run HW5 setup.sh first to create the database."
    exit 1
elif [ "${INSTANCE_STATUS}" = "STOPPED" ]; then
    echo "  Instance is STOPPED — starting ..."
    gcloud sql instances patch "${SQL_INSTANCE}" \
        --project="${PROJECT_ID}" \
        --activation-policy=ALWAYS \
        --quiet
    echo "  Waiting for instance to become RUNNABLE ..."
    for i in $(seq 1 30); do
        ST=$(gcloud sql instances describe "${SQL_INSTANCE}" \
            --project="${PROJECT_ID}" \
            --format="value(state)" 2>/dev/null || echo "UNKNOWN")
        echo "    state=${ST} (attempt ${i}/30)"
        [ "${ST}" = "RUNNABLE" ] && break
        sleep 10
    done
elif [ "${INSTANCE_STATUS}" = "RUNNABLE" ]; then
    echo "  Instance already RUNNABLE."
else
    echo "  Instance state: ${INSTANCE_STATUS} — waiting ..."
    for i in $(seq 1 30); do
        ST=$(gcloud sql instances describe "${SQL_INSTANCE}" \
            --project="${PROJECT_ID}" \
            --format="value(state)" 2>/dev/null || echo "UNKNOWN")
        echo "    state=${ST} (attempt ${i}/30)"
        [ "${ST}" = "RUNNABLE" ] && break
        sleep 10
    done
fi

DB_CONN_NAME=$(gcloud sql instances describe "${SQL_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --format="value(connectionName)")
echo "  DB_CONN_NAME=${DB_CONN_NAME}"

# ── [4/9] Service account ────────────────────────────────────────────────────
echo "[4/9] Creating service account and IAM bindings ..."
gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="HW6 ML VM SA" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  SA ${SA_NAME} already exists."

for role in roles/cloudsql.client roles/storage.objectAdmin; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_EMAIL}" --role="${role}" --quiet
done

# ── [5/9] Remove old DONE marker if exists ───────────────────────────────────
echo "[5/9] Cleaning up previous run markers ..."
gcloud storage rm "gs://${BUCKET_NAME}/hw6/DONE" 2>/dev/null || true

# ── [6/9] Create ML VM ──────────────────────────────────────────────────────
echo "[6/9] Creating ML VM '${VM_NAME}' ..."

# Delete existing VM if present (from a failed prior run)
gcloud compute instances delete "${VM_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true

gcloud compute instances create "${VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="e2-standard-2" \
    --image-family="debian-12" \
    --image-project="debian-cloud" \
    --service-account="${SA_EMAIL}" \
    --scopes="cloud-platform" \
    --project="${PROJECT_ID}" \
    --metadata="project-id=${PROJECT_ID},bucket-name=${BUCKET_NAME},db-name=${DB_NAME},db-user=${DB_USER},db-password=${DB_PASSWORD},db-conn-name=${DB_CONN_NAME}" \
    --metadata-from-file="startup-script=startup.sh" \
    --quiet
echo "  VM created. Startup script will install dependencies and run models."

# ── [7/9] Wait for models to complete ────────────────────────────────────────
echo "[7/9] Waiting for models to complete (polling GCS for DONE marker) ..."
echo "  This may take 5-10 minutes (installing packages + training) ..."

MAX_ATTEMPTS=60
for i in $(seq 1 ${MAX_ATTEMPTS}); do
    if gcloud storage cat "gs://${BUCKET_NAME}/hw6/DONE" 2>/dev/null | grep -q "HW6_COMPLETE"; then
        echo "  Models completed! (attempt ${i})"
        break
    fi
    if [ "${i}" -eq "${MAX_ATTEMPTS}" ]; then
        echo "  WARNING: Timed out after ${MAX_ATTEMPTS} attempts."
        echo "  Check VM serial console: gcloud compute instances get-serial-port-output ${VM_NAME} --zone=${ZONE} --project=${PROJECT_ID}"
    fi
    echo "    Not done yet (attempt ${i}/${MAX_ATTEMPTS}), waiting 30s ..."
    sleep 30
done

# ── [8/9] Print model output ─────────────────────────────────────────────────
echo ""
echo "[8/9] ============================================================"
echo "       MODEL RESULTS FROM GCS"
echo "       ============================================================"
echo ""

echo "--- 3NF Normalization Output ---"
gcloud storage cat "gs://${BUCKET_NAME}/hw6/normalize_output.txt" 2>/dev/null || echo "  (not found)"
echo ""

echo "--- Model 1 Results (IP -> Country) ---"
gcloud storage cat "gs://${BUCKET_NAME}/hw6/model1_results.txt" 2>/dev/null || echo "  (not found)"
echo ""

echo "--- Model 2 Results (Fields -> Income) ---"
gcloud storage cat "gs://${BUCKET_NAME}/hw6/model2_results.txt" 2>/dev/null || echo "  (not found)"
echo ""

echo "--- Models Console Output ---"
gcloud storage cat "gs://${BUCKET_NAME}/hw6/models_output.txt" 2>/dev/null || echo "  (not found)"
echo ""

# ── [9/9] Cleanup: delete VM and stop DB ─────────────────────────────────────
echo "[9/9] Cleaning up ..."

echo "  Deleting VM '${VM_NAME}' ..."
gcloud compute instances delete "${VM_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true

echo "  Stopping Cloud SQL instance '${SQL_INSTANCE}' ..."
gcloud sql instances patch "${SQL_INSTANCE}" \
    --activation-policy=NEVER \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# Remove IAM bindings and SA
for role in roles/cloudsql.client roles/storage.objectAdmin; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_EMAIL}" --role="${role}" \
        --quiet 2>/dev/null || true
done

gcloud iam service-accounts delete "${SA_EMAIL}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || true

echo ""
echo "=== HW6 Setup Complete ==="
echo "  VM '${VM_NAME}' deleted."
echo "  Cloud SQL '${SQL_INSTANCE}' stopped."
echo "  Results available at: gs://${BUCKET_NAME}/hw6/"
