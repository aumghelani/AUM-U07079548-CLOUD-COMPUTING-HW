#!/bin/bash
# startup.sh - Configures the HW6 ML VM on first boot.
# Passed via: --metadata-from-file startup-script=startup.sh
# Runs as root automatically.

# ── Run-once guard ────────────────────────────────────────────────────────────
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran. Skipping."
    exit 0
fi

set -e
export DEBIAN_FRONTEND=noninteractive
echo "[startup] Beginning first-time setup for HW6 ML VM ..."

# ── Read instance metadata ────────────────────────────────────────────────────
META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/project-id")
BUCKET_NAME=$(curl -sf -H "Metadata-Flavor: Google" "${META}/bucket-name")
DB_NAME=$(curl -sf -H "Metadata-Flavor: Google" "${META}/db-name"            || echo "hw5db")
DB_USER=$(curl -sf -H "Metadata-Flavor: Google" "${META}/db-user"            || echo "hw5user")
DB_PASSWORD=$(curl -sf -H "Metadata-Flavor: Google" "${META}/db-password")
DB_CONN_NAME=$(curl -sf -H "Metadata-Flavor: Google" "${META}/db-conn-name")

echo "[startup] PROJECT_ID=${PROJECT_ID}, BUCKET=${BUCKET_NAME}"
echo "[startup] DB_CONN_NAME=${DB_CONN_NAME}"

# ── Install system dependencies ───────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl wget

# ── Install Cloud SQL Auth Proxy (v2) ────────────────────────────────────────
echo "[startup] Installing Cloud SQL Auth Proxy v2 ..."
wget -q "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.14.1/cloud-sql-proxy.linux.amd64" \
    -O /usr/local/bin/cloud-sql-proxy
chmod +x /usr/local/bin/cloud-sql-proxy

# ── Create systemd unit for Cloud SQL Auth Proxy ──────────────────────────────
cat > /etc/systemd/system/cloud-sql-proxy.service <<UNIT
[Unit]
Description=Cloud SQL Auth Proxy v2
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloud-sql-proxy ${DB_CONN_NAME} --port=3306
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable cloud-sql-proxy
systemctl start cloud-sql-proxy

# ── Set up Python virtual environment with ML libraries ──────────────────────
mkdir -p /opt/hw6
python3 -m venv /opt/hw6/venv
/opt/hw6/venv/bin/pip install --quiet \
    pymysql \
    cryptography \
    numpy \
    scikit-learn \
    google-cloud-storage \
    "google-auth==2.29.0"

# ── Download scripts from GCS ────────────────────────────────────────────────
echo "[startup] Downloading HW6 scripts from GCS ..."
gcloud storage cp "gs://${BUCKET_NAME}/hw6-scripts/normalize_schema.py" /opt/hw6/normalize_schema.py
gcloud storage cp "gs://${BUCKET_NAME}/hw6-scripts/models.py"           /opt/hw6/models.py

# ── Wait for Cloud SQL Proxy to be ready ─────────────────────────────────────
echo "[startup] Waiting for Cloud SQL Proxy on 127.0.0.1:3306 ..."
for i in $(seq 1 30); do
    if /opt/hw6/venv/bin/python -c \
        "import pymysql; pymysql.connect(host='127.0.0.1',port=3306,user='${DB_USER}',password='${DB_PASSWORD}',connect_timeout=3)" \
        2>/dev/null; then
        echo "  Proxy ready (attempt ${i})."
        break
    fi
    echo "  Not ready yet (attempt ${i}/30), waiting 5s ..."
    sleep 5
done

# ── Create environment file ──────────────────────────────────────────────────
cat > /opt/hw6/hw6.env <<EOF
PROJECT_ID=${PROJECT_ID}
BUCKET_NAME=${BUCKET_NAME}
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
EOF

# ── Run 3NF normalization ────────────────────────────────────────────────────
echo "[startup] Running 3NF schema normalization ..."
set -a; source /opt/hw6/hw6.env; set +a
/opt/hw6/venv/bin/python /opt/hw6/normalize_schema.py 2>&1 | tee /opt/hw6/normalize_output.txt

# ── Run ML models ────────────────────────────────────────────────────────────
echo "[startup] Running ML models ..."
/opt/hw6/venv/bin/python /opt/hw6/models.py 2>&1 | tee /opt/hw6/models_output.txt

# ── Upload console output to GCS as well ─────────────────────────────────────
gcloud storage cp /opt/hw6/normalize_output.txt "gs://${BUCKET_NAME}/hw6/normalize_output.txt"
gcloud storage cp /opt/hw6/models_output.txt    "gs://${BUCKET_NAME}/hw6/models_output.txt"

# ── Signal completion ────────────────────────────────────────────────────────
touch /opt/hw6/DONE
echo "HW6_COMPLETE" | gcloud storage cp - "gs://${BUCKET_NAME}/hw6/DONE"

# ── Lock file ────────────────────────────────────────────────────────────────
touch /var/log/startup_already_done
echo "[startup] HW6 setup complete. Models have run and results uploaded."
