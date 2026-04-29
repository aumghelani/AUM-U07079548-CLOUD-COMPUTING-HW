#!/bin/bash
# setup.sh - HW9: Port HW4 web server onto GKE.
# Run from the hw9/ directory: bash setup.sh
#
# IMPORTANT: This script deploys to Kubernetes using ONLY imperative
# `kubectl` commands (no YAML manifests), following the workflow shown
# in Lecture 21:
#   1. Create the Deployment imperatively.
#   2. Expose it imperatively as a LoadBalancer Service.
#   3. Create a Kubernetes ServiceAccount imperatively.
#   4. Annotate it with the Google SA email (Workload Identity).
#   5. Patch the Deployment to use that KSA via `kubectl set serviceaccount`.
#
# Creates:
#   - Artifact Registry repository (for the container image)
#   - Container image built from hw9/Dockerfile via Cloud Build
#   - GKE cluster (regional, us-central1)
#   - Pub/Sub topic + subscription (forbidden-requests)
#   - Google service account for the web server + IAM bindings
#   - Kubernetes ServiceAccount bound to the GSA (Workload Identity)
#   - Kubernetes Deployment (2 replicas) + LoadBalancer Service (port 80 -> 8080)
#   - VM running service2.py (Pub/Sub subscriber)
#   - VM for running http_client.py

set -e
export DEBIAN_FRONTEND=noninteractive

# ── Hardcoded project values ─────────────────────────────────────────────────
PROJECT_ID="u0709548-aum-hw1"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

REGION="us-central1"
ZONE="us-central1-a"

BUCKET_NAME="aum-hw2-u07079548"
FILE_PREFIX="hw2/"
SCRIPTS_BUCKET="${BUCKET_NAME}"

TOPIC_ID="forbidden-requests"
SUBSCRIPTION_ID="forbidden-requests-sub"

# GKE / image
CLUSTER_NAME="hw9-cluster"
AR_REPO="hw9-images"
IMAGE_NAME="hw9-webserver"
IMAGE_TAG="v1"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

# IAM
GSA_NAME="hw9-ws-sa"          # Google service account (used by GKE workload)
GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SA_SERVICE2="hw9-service2-sa" # VM service account for the Pub/Sub subscriber
SA2_EMAIL="${SA_SERVICE2}@${PROJECT_ID}.iam.gserviceaccount.com"

K8S_NAMESPACE="default"
K8S_SA="hw9-ksa"
DEPLOYMENT_NAME="hw9-webserver"
SERVICE_NAME="hw9-webserver"

# VMs (Service 2 subscriber + client VM)
VM_SERVICE2="hw9-service2-vm"
VM_CLIENT="hw9-client-vm"

echo "=== HW9 Setup ==="
echo "Project: ${PROJECT_ID} (${PROJECT_NUMBER})"
echo "Region:  ${REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Image:   ${IMAGE_URI}"

# ── Enable APIs ──────────────────────────────────────────────────────────────
echo "[1/12] Enabling APIs ..."
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    pubsub.googleapis.com \
    logging.googleapis.com \
    storage.googleapis.com \
    iamcredentials.googleapis.com \
    --project="${PROJECT_ID}" --quiet

# ── Upload scripts (for VM startup scripts to pull) ─────────────────────────
echo "[2/12] Uploading service2.py + http_client.py to GCS ..."
gcloud storage cp service2.py    "gs://${SCRIPTS_BUCKET}/hw9-scripts/service2.py"    --project="${PROJECT_ID}"
gcloud storage cp http_client.py "gs://${SCRIPTS_BUCKET}/hw9-scripts/http_client.py" --project="${PROJECT_ID}"

# ── Pub/Sub ──────────────────────────────────────────────────────────────────
echo "[3/12] Creating Pub/Sub topic + subscription ..."
gcloud pubsub topics create "${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Topic already exists."
gcloud pubsub subscriptions create "${SUBSCRIPTION_ID}" \
    --topic="${TOPIC_ID}" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Subscription already exists."

# ── Artifact Registry ────────────────────────────────────────────────────────
echo "[4/12] Creating Artifact Registry repo ${AR_REPO} ..."
gcloud artifacts repositories create "${AR_REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="HW9 images" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  Repo already exists."

# ── Build image with Cloud Build ─────────────────────────────────────────────
echo "[5/12] Building container image via Cloud Build ..."
gcloud builds submit \
    --tag "${IMAGE_URI}" \
    --project="${PROJECT_ID}" \
    --quiet \
    .

# ── Service accounts (GSA for GKE workload, SA for VM) ───────────────────────
echo "[6/12] Creating service accounts + IAM bindings ..."
gcloud iam service-accounts create "${GSA_NAME}" \
    --display-name="HW9 GKE Web Server" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  GSA already exists."

gcloud iam service-accounts create "${SA_SERVICE2}" \
    --display-name="HW9 Service 2 Reporter" \
    --project="${PROJECT_ID}" --quiet 2>/dev/null || echo "  SA2 already exists."

# GSA: read bucket + write logs + publish forbidden msgs
for ROLE in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${GSA_EMAIL}" \
        --role="${ROLE}" --quiet > /dev/null
done

# SA2: consume Pub/Sub, read scripts from GCS
for ROLE in roles/pubsub.subscriber roles/storage.objectViewer; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA2_EMAIL}" \
        --role="${ROLE}" --quiet > /dev/null
done

# ── Create GKE cluster ───────────────────────────────────────────────────────
echo "[7/12] Creating GKE cluster (this takes ~5-7 minutes) ..."
if gcloud container clusters describe "${CLUSTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
    echo "  Cluster already exists."
else
    gcloud container clusters create-auto "${CLUSTER_NAME}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --release-channel=regular \
        --quiet
fi

# Fetch kubeconfig
echo "  Fetching kubeconfig ..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" --quiet

# ── Workload Identity binding (KSA -> GSA) at the IAM layer ──────────────────
# This is the project-side half: it tells GCP that the Kubernetes SA
# (default/hw9-ksa) is allowed to act as the Google SA hw9-ws-sa.
echo "[8/12] Granting KSA permission to impersonate GSA (Workload Identity) ..."
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA}]" \
    --project="${PROJECT_ID}" --quiet > /dev/null

# ── Imperative deploy: kubectl commands only, no YAML files ──────────────────
echo "[9/12] Deploying to GKE with kubectl (imperative — no YAML) ..."

# Clean slate if any of these already exist (so the script is idempotent).
kubectl delete deployment "${DEPLOYMENT_NAME}" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
kubectl delete service    "${SERVICE_NAME}"    --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
kubectl delete sa         "${K8S_SA}"          --ignore-not-found=true --wait=true >/dev/null 2>&1 || true

# Step 9.1 — Create the Deployment imperatively.
echo "  [9.1] kubectl create deployment ${DEPLOYMENT_NAME} ..."
kubectl create deployment "${DEPLOYMENT_NAME}" \
    --image="${IMAGE_URI}" \
    --replicas=2

# Step 9.2 — Pass env vars + container port to the pod.
# (kubectl create deployment does not take env flags; use kubectl set env
# and patch the container port via kubectl set.)
echo "  [9.2] kubectl set env / kubectl set image ..."
kubectl set env deployment/"${DEPLOYMENT_NAME}" \
    PROJECT_ID="${PROJECT_ID}" \
    BUCKET_NAME="${BUCKET_NAME}" \
    FILE_PREFIX="${FILE_PREFIX}" \
    TOPIC_ID="${TOPIC_ID}" \
    PORT="8080"

# Step 9.3 — Expose the deployment as a LoadBalancer on port 80 -> 8080.
echo "  [9.3] kubectl expose deployment ${DEPLOYMENT_NAME} as LoadBalancer ..."
kubectl expose deployment "${DEPLOYMENT_NAME}" \
    --type=LoadBalancer \
    --name="${SERVICE_NAME}" \
    --port=80 \
    --target-port=8080

# Step 9.4 — Create the Kubernetes ServiceAccount imperatively.
echo "  [9.4] kubectl create serviceaccount ${K8S_SA} ..."
kubectl create serviceaccount "${K8S_SA}"

# Step 9.5 — Annotate the KSA with the Google SA email (Workload Identity).
echo "  [9.5] kubectl annotate serviceaccount ${K8S_SA} ..."
kubectl annotate serviceaccount "${K8S_SA}" \
    iam.gke.io/gcp-service-account="${GSA_EMAIL}" \
    --overwrite

# Step 9.6 — Attach the KSA to the Deployment.
# `kubectl set serviceaccount` sets the pod template's serviceAccountName field
# (this is the imperative equivalent of editing the YAML to add
# `serviceAccountName: hw9-ksa`).
echo "  [9.6] kubectl set serviceaccount deployment/${DEPLOYMENT_NAME} ${K8S_SA} ..."
kubectl set serviceaccount deployment/"${DEPLOYMENT_NAME}" "${K8S_SA}"

# Step 9.7 — Wait for the rollout to complete.
echo "  [9.7] kubectl rollout status ..."
kubectl rollout status deployment/"${DEPLOYMENT_NAME}" --timeout=300s || true

# Step 9.8 — Wait for the LoadBalancer to get an external IP.
echo "  Waiting for LoadBalancer external IP (up to 3 minutes) ..."
LB_IP=""
for i in $(seq 1 36); do
    LB_IP=$(kubectl get service "${SERVICE_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "${LB_IP}" ]; then
        echo "  LoadBalancer IP: ${LB_IP}"
        break
    fi
    sleep 5
done
if [ -z "${LB_IP}" ]; then
    echo "  WARNING: LoadBalancer IP not ready yet. Check with: kubectl get svc ${SERVICE_NAME}"
fi

# ── Create Service 2 VM ──────────────────────────────────────────────────────
echo "[10/12] Creating Service 2 VM (Pub/Sub subscriber) ..."
if gcloud compute instances describe "${VM_SERVICE2}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
    echo "  Service 2 VM already exists."
else
    gcloud compute instances create "${VM_SERVICE2}" \
        --zone="${ZONE}" \
        --machine-type="e2-micro" \
        --image-family="debian-12" \
        --image-project="debian-cloud" \
        --service-account="${SA2_EMAIL}" \
        --scopes="cloud-platform" \
        --metadata="project-id=${PROJECT_ID},subscription-id=${SUBSCRIPTION_ID},scripts-bucket=${SCRIPTS_BUCKET}" \
        --metadata-from-file="startup-script=startup_service2.sh" \
        --project="${PROJECT_ID}" --quiet
fi

# ── Create Client VM ─────────────────────────────────────────────────────────
echo "[11/12] Creating Client VM ..."
if gcloud compute instances describe "${VM_CLIENT}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
    echo "  Client VM already exists."
else
    gcloud compute instances create "${VM_CLIENT}" \
        --zone="${ZONE}" \
        --machine-type="e2-micro" \
        --image-family="debian-12" \
        --image-project="debian-cloud" \
        --service-account="${SA2_EMAIL}" \
        --scopes="cloud-platform" \
        --metadata="project-id=${PROJECT_ID},scripts-bucket=${SCRIPTS_BUCKET}" \
        --metadata-from-file="startup-script=startup_client.sh" \
        --project="${PROJECT_ID}" --quiet
fi

# ── Grader access ────────────────────────────────────────────────────────────
echo ""
echo "[12/12] Granting grader access ..."
for EMAIL in adrishd@bu.edu bpri1504@bu.edu; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="user:${EMAIL}" \
        --role="roles/editor" --quiet > /dev/null 2>&1 || true
done

echo ""
echo "================================================================"
echo "=== HW9 Setup Complete ==="
echo "================================================================"
echo ""
echo "  LoadBalancer IP   : ${LB_IP}"
echo "  Cluster           : ${CLUSTER_NAME} (region=${REGION})"
echo "  Image             : ${IMAGE_URI}"
echo "  Service 2 VM      : ${VM_SERVICE2}  (zone=${ZONE})"
echo "  Client VM         : ${VM_CLIENT}    (zone=${ZONE})"
echo ""
echo "  Test with curl:"
echo "    curl -v http://${LB_IP}/0.html            # expect 200"
echo "    curl -v http://${LB_IP}/nothere.html      # expect 404"
echo "    curl -v -X POST http://${LB_IP}/0.html    # expect 501"
echo "    curl -v -H 'X-country: Iran' http://${LB_IP}/0.html  # expect 403"
echo ""
echo "  Run the HTTP client (on the client VM):"
echo "    gcloud compute ssh ${VM_CLIENT} --zone=${ZONE}"
echo "    sudo SERVER_HOST=${LB_IP} \$HW9_PY \$HW9_CLIENT"
echo ""
echo "  Watch Service 2 output:"
echo "    gcloud compute ssh ${VM_SERVICE2} --zone=${ZONE} --command='sudo journalctl -u service2 -f'"
echo ""
echo "  Kubernetes views:"
echo "    kubectl get pods"
echo "    kubectl get svc ${SERVICE_NAME}"
echo "    kubectl get deployment ${DEPLOYMENT_NAME}"
echo "    kubectl get sa ${K8S_SA} -o yaml"
echo ""
echo "================================================================"
