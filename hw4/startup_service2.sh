#!/bin/bash
# startup_service2.sh - Configures VM3 (forbidden country reporter) on first boot.
# Passed to the VM via: --metadata-from-file startup-script=startup_service2.sh
# Runs as root automatically.

# ── Run-once guard ────────────────────────────────────────────────────────────
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran. Skipping."
    exit 0
fi

set -e
echo "[startup] Beginning first-time setup for Service 2 ..."

# ── Read instance metadata ────────────────────────────────────────────────────
META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/project-id")
SUBSCRIPTION_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/subscription-id")
SCRIPTS_BUCKET=$(curl -sf -H "Metadata-Flavor: Google" "${META}/scripts-bucket")

echo "[startup] PROJECT_ID=${PROJECT_ID}, SUBSCRIPTION=${SUBSCRIPTION_ID}"

# ── Install system dependencies ───────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl

# ── Set up Python virtual environment ────────────────────────────────────────
mkdir -p /opt/service2
python3 -m venv /opt/service2/venv
/opt/service2/venv/bin/pip install --quiet google-cloud-pubsub

# ── Download service2.py from GCS ────────────────────────────────────────────
gcloud storage cp "gs://${SCRIPTS_BUCKET}/hw4-scripts/service2.py" /opt/service2/service2.py

# ── Create systemd environment file ──────────────────────────────────────────
cat > /opt/service2/service2.env <<EOF
PROJECT_ID=${PROJECT_ID}
SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
EOF

# ── Create systemd service unit ───────────────────────────────────────────────
cat > /etc/systemd/system/service2.service <<'UNIT'
[Unit]
Description=HW4 Service 2 - Forbidden Country Reporter
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/service2
EnvironmentFile=/opt/service2/service2.env
ExecStart=/opt/service2/venv/bin/python /opt/service2/service2.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# ── Enable and start the service ──────────────────────────────────────────────
systemctl daemon-reload
systemctl enable service2
systemctl start service2

# ── Lock file to prevent re-running ──────────────────────────────────────────
touch /var/log/startup_already_done
echo "[startup] Service 2 setup complete and running."
