#!/bin/bash
# run_local.sh - Run both Apache Beam pipelines locally (DirectRunner).
# Run from hw7/ directory: bash run_local.sh
#
# Prerequisites:
#   pip install "apache-beam[gcp]" google-cloud-storage
#   gcloud auth application-default login

set -e

echo "=== HW7 Local Run (DirectRunner) ==="
echo ""

# ── Pipeline 1: Link Analysis ────────────────────────────────────────────────
echo "--- Running Link Analysis Pipeline ---"
START1=$(date +%s)

python link_analysis.py --runner DirectRunner

END1=$(date +%s)
ELAPSED1=$((END1 - START1))
echo ""
echo "Link Analysis runtime: ${ELAPSED1} seconds"
echo ""

# ── Pipeline 2: Bigram Analysis ──────────────────────────────────────────────
echo "--- Running Bigram Analysis Pipeline ---"
START2=$(date +%s)

python bigram_analysis.py --runner DirectRunner

END2=$(date +%s)
ELAPSED2=$((END2 - START2))
echo ""
echo "Bigram Analysis runtime: ${ELAPSED2} seconds"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
TOTAL=$((ELAPSED1 + ELAPSED2))
echo "=========================================="
echo "=== Local Run Complete ==="
echo "=========================================="
echo "  Link Analysis  : ${ELAPSED1} seconds"
echo "  Bigram Analysis: ${ELAPSED2} seconds"
echo "  Total          : ${TOTAL} seconds"
