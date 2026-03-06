#!/bin/bash
# startup_service1.sh - Configures VM1 (web server) on first boot.
# Passed to the VM via: --metadata-from-file startup-script=startup_service1.sh
# Runs as root automatically.

# ── Run-once guard ────────────────────────────────────────────────────────────
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran. Skipping."
    exit 0
fi

set -e
echo "[startup] Beginning first-time setup for Service 1 ..."

# ── Read instance metadata ────────────────────────────────────────────────────
META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/project-id")
BUCKET_NAME=$(curl -sf -H "Metadata-Flavor: Google" "${META}/bucket-name")
TOPIC_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/topic-id")
FILE_PREFIX=$(curl -sf -H "Metadata-Flavor: Google" "${META}/file-prefix" || echo "hw2/")
PORT=$(curl -sf -H "Metadata-Flavor: Google" "${META}/port" || echo "80")
SCRIPTS_BUCKET=$(curl -sf -H "Metadata-Flavor: Google" "${META}/scripts-bucket")

echo "[startup] PROJECT_ID=${PROJECT_ID}, BUCKET=${BUCKET_NAME}, PORT=${PORT}"

# ── Install system dependencies ───────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl

# ── Set up Python virtual environment ────────────────────────────────────────
python3 -m venv /opt/service1/venv
/opt/service1/venv/bin/pip install --quiet \
    google-cloud-storage \
    google-cloud-logging \
    google-cloud-pubsub

# ── Download service1.py from GCS ────────────────────────────────────────────
mkdir -p /opt/service1
/opt/service1/venv/bin/python -m pip install --quiet google-cloud-storage
gcloud storage cp "gs://${SCRIPTS_BUCKET}/hw4-scripts/service1.py" /opt/service1/service1.py

# ── Create systemd environment file ──────────────────────────────────────────
cat > /opt/service1/service1.env <<EOF
PROJECT_ID=${PROJECT_ID}
BUCKET_NAME=${BUCKET_NAME}
TOPIC_ID=${TOPIC_ID}
FILE_PREFIX=${FILE_PREFIX}
PORT=${PORT}
EOF

# ── Create systemd service unit ───────────────────────────────────────────────
cat > /etc/systemd/system/service1.service <<'UNIT'
[Unit]
Description=HW4 Service 1 - Python HTTP Web Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/service1
EnvironmentFile=/opt/service1/service1.env
ExecStart=/opt/service1/venv/bin/python /opt/service1/service1.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# ── Enable and start the service ──────────────────────────────────────────────
systemctl daemon-reload
systemctl enable service1
systemctl start service1

# ── Lock file to prevent re-running ──────────────────────────────────────────
touch /var/log/startup_already_done
echo "[startup] Service 1 setup complete and running."
