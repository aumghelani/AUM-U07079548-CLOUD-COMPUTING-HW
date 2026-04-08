#!/bin/bash
# run_dataflow.sh - Run both Apache Beam pipelines on Cloud Dataflow.
# Run from hw7/ directory: bash run_dataflow.sh
#
# Prerequisites:
#   pip install "apache-beam[gcp]"
#   gcloud auth application-default login
#   Dataflow API enabled

set -e

PROJECT_ID="u0709548-aum-hw1"
REGION="us-west1"
BUCKET="aum-hw2-u07079548"

echo "=== HW7 Cloud Dataflow Run ==="
echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"
echo ""

# Enable Dataflow API
echo "Enabling Dataflow API ..."
gcloud services enable dataflow.googleapis.com --project="${PROJECT_ID}" --quiet

# ── Pipeline 1: Link Analysis ────────────────────────────────────────────────
echo ""
echo "--- Running Link Analysis Pipeline on Dataflow ---"
START1=$(date +%s)

python link_analysis.py \
    --runner DataflowRunner \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --temp_location "gs://${BUCKET}/hw7-temp/links/" \
    --staging_location "gs://${BUCKET}/hw7-staging/links/" \
    --job_name "hw7-link-analysis-$(date +%s)" \
    --worker_machine_type e2-medium \
    --max_num_workers 2 \
    --save_main_session

END1=$(date +%s)
ELAPSED1=$((END1 - START1))
echo ""
echo "Link Analysis Dataflow runtime: ${ELAPSED1} seconds"
echo ""

# ── Pipeline 2: Bigram Analysis ──────────────────────────────────────────────
echo "--- Running Bigram Analysis Pipeline on Dataflow ---"
START2=$(date +%s)

python bigram_analysis.py \
    --runner DataflowRunner \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --temp_location "gs://${BUCKET}/hw7-temp/bigrams/" \
    --staging_location "gs://${BUCKET}/hw7-staging/bigrams/" \
    --job_name "hw7-bigram-analysis-$(date +%s)" \
    --worker_machine_type e2-medium \
    --max_num_workers 2 \
    --save_main_session

END2=$(date +%s)
ELAPSED2=$((END2 - START2))
echo ""
echo "Bigram Analysis Dataflow runtime: ${ELAPSED2} seconds"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
TOTAL=$((ELAPSED1 + ELAPSED2))
echo "=========================================="
echo "=== Dataflow Run Complete ==="
echo "=========================================="
echo "  Link Analysis  : ${ELAPSED1} seconds"
echo "  Bigram Analysis: ${ELAPSED2} seconds"
echo "  Total          : ${TOTAL} seconds"
echo ""
echo "Check Dataflow jobs at:"
echo "  https://console.cloud.google.com/dataflow/jobs?project=${PROJECT_ID}"
