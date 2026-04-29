#!/bin/bash
# cleanup.sh - Tears down everything setup.sh created for HW9.
# Run from the hw9/ directory: bash cleanup.sh

set +e
export DEBIAN_FRONTEND=noninteractive

PROJECT_ID="u0709548-aum-hw1"

REGION="us-central1"
ZONE="us-central1-a"

BUCKET_NAME="aum-hw2-u07079548"
SCRIPTS_BUCKET="${BUCKET_NAME}"

TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

CLUSTER_NAME="hw9-cluster"
AR_REPO="hw9-images"

GSA_NAME="hw9-ws-sa"
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SA_SERVICE2="hw9-service2-sa"
SA2_EMAIL="${SA_SERVICE2}@${PROJECT_ID}.iam.gserviceaccount.com"

VM_SERVICE2="hw9-service2-vm"
VM_CLIENT="hw9-client-vm"

echo "=== HW9 Cleanup ==="
echo "Project: ${PROJECT_ID}"

# ── Delete k8s resources first (so the LB IP gets released cleanly) ──────────
echo "[1/9] Deleting Kubernetes resources ..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true

kubectl delete service    hw9-webserver --ignore-not-found=true --timeout=120s 2>/dev/null || true
kubectl delete deployment hw9-webserver --ignore-not-found=true --timeout=120s 2>/dev/null || true
kubectl delete sa         hw9-ksa       --ignore-not-found=true --timeout=60s  2>/dev/null || true

# ── Delete GKE cluster ───────────────────────────────────────────────────────
echo "[2/9] Deleting GKE cluster ..."
gcloud container clusters delete "${CLUSTER_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  Cluster not found, skipping."

# ── Delete VMs ───────────────────────────────────────────────────────────────
echo "[3/9] Deleting VMs ..."
gcloud compute instances delete "${VM_SERVICE2}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  ${VM_SERVICE2} not found, skipping."
gcloud compute instances delete "${VM_CLIENT}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  ${VM_CLIENT} not found, skipping."

# ── Pub/Sub ──────────────────────────────────────────────────────────────────
echo "[4/9] Deleting Pub/Sub subscription + topic ..."
gcloud pubsub subscriptions delete "${SUBSCRIPTION_ID}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  Subscription not found."
gcloud pubsub topics delete "${TOPIC_ID}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  Topic not found."

# ── Remove IAM bindings ──────────────────────────────────────────────────────
echo "[5/9] Removing IAM bindings for GSA ..."
for ROLE in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${GSA_EMAIL}" \
        --role="${ROLE}" --quiet 2>/dev/null || true
done

echo "[6/9] Removing IAM bindings for SA2 ..."
for ROLE in roles/pubsub.subscriber roles/storage.objectViewer; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA2_EMAIL}" \
        --role="${ROLE}" --quiet 2>/dev/null || true
done

# ── Delete service accounts ──────────────────────────────────────────────────
echo "[7/9] Deleting service accounts ..."
gcloud iam service-accounts delete "${GSA_EMAIL}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  GSA not found."
gcloud iam service-accounts delete "${SA2_EMAIL}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  SA2 not found."

# ── Artifact Registry ────────────────────────────────────────────────────────
echo "[8/9] Deleting Artifact Registry repo (and all images in it) ..."
gcloud artifacts repositories delete "${AR_REPO}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null \
    || echo "  Repo not found."

# ── Remove uploaded scripts ──────────────────────────────────────────────────
echo "[9/9] Removing hw9-scripts from GCS ..."
gcloud storage rm --recursive "gs://${SCRIPTS_BUCKET}/hw9-scripts/" --project="${PROJECT_ID}" 2>/dev/null \
    || echo "  hw9-scripts not found in GCS."

# (no local rendered manifests in the imperative-only flow)

echo ""
echo "=== Cleanup Complete ==="
echo "  NOTE: The HW2 bucket (gs://${BUCKET_NAME}) and its data files were NOT deleted."
