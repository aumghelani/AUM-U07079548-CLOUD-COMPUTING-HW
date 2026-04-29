#!/bin/bash
# startup_service2.sh - configures the second-app VM on first boot.
# Runs as root (GCE startup scripts always do).

if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran. Skipping."
    exit 0
fi

set -e
export DEBIAN_FRONTEND=noninteractive
echo "[startup] HW9 Service 2 VM first-time setup ..."

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/project-id")
SUBSCRIPTION_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/subscription-id")
SCRIPTS_BUCKET=$(curl -sf -H "Metadata-Flavor: Google" "${META}/scripts-bucket")

echo "[startup] PROJECT_ID=${PROJECT_ID}, SUB=${SUBSCRIPTION_ID}"

apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl

mkdir -p /opt/service2
python3 -m venv /opt/service2/venv
/opt/service2/venv/bin/pip install --quiet \
    "google-cloud-pubsub==2.26.1" \
    "google-auth==2.29.0"

gcloud storage cp "gs://${SCRIPTS_BUCKET}/hw9-scripts/service2.py" /opt/service2/service2.py

cat > /opt/service2/service2.env <<EOF
PROJECT_ID=${PROJECT_ID}
SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
EOF

cat > /etc/systemd/system/service2.service <<'UNIT'
[Unit]
Description=HW9 Service 2 - Forbidden Country Reporter
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

systemctl daemon-reload
systemctl enable service2
systemctl start service2

touch /var/log/startup_already_done
echo "[startup] HW9 Service 2 running."
