#!/bin/bash
# startup_client.sh - Configures VM2 (HTTP client VM) on first boot.
# Installs Python and downloads http_client.py from GCS.

# ── Run-once guard ────────────────────────────────────────────────────────────
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran. Skipping."
    exit 0
fi

set -e
echo "[startup] Setting up client VM ..."

# ── Read instance metadata ────────────────────────────────────────────────────
META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/project-id")
BUCKET_NAME=$(curl -sf -H "Metadata-Flavor: Google" "${META}/bucket-name")
SCRIPTS_BUCKET=$(curl -sf -H "Metadata-Flavor: Google" "${META}/scripts-bucket")
SERVER_HOST=$(curl -sf -H "Metadata-Flavor: Google" "${META}/server-host")

# ── Install dependencies ──────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl

mkdir -p /opt/client
python3 -m venv /opt/client/venv
/opt/client/venv/bin/pip install --quiet google-cloud-storage

# ── Download http_client.py from GCS ─────────────────────────────────────────
gcloud storage cp "gs://${SCRIPTS_BUCKET}/hw4-scripts/http_client.py" /opt/client/http_client.py

# ── Write a convenience run script ───────────────────────────────────────────
cat > /opt/client/run_client.sh <<EOF
#!/bin/bash
# Run the HTTP client against the web server.
# Usage: bash /opt/client/run_client.sh [NUM_FILES]
export PROJECT_ID="${PROJECT_ID}"
export BUCKET_NAME="${BUCKET_NAME}"
export SERVER_HOST="${SERVER_HOST}"
export SERVER_PORT="80"
export MAX_FILES="\${1:-100}"
/opt/client/venv/bin/python /opt/client/http_client.py
EOF
chmod +x /opt/client/run_client.sh

touch /var/log/startup_already_done
echo "[startup] Client VM setup complete."
echo "[startup] Run: bash /opt/client/run_client.sh"
