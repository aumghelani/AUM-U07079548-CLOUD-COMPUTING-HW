#!/bin/bash
# startup.sh - Configures the HW5 web-server VM (VM1) on first boot.
# Passed to the VM via: --metadata-from-file startup-script=startup.sh
# Runs as root automatically.

# ── Run-once guard ────────────────────────────────────────────────────────────
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran. Skipping."
    exit 0
fi

set -e
export DEBIAN_FRONTEND=noninteractive
echo "[startup] Beginning first-time setup for HW5 Service 1 ..."

# ── Read instance metadata ────────────────────────────────────────────────────
META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/project-id")
BUCKET_NAME=$(curl -sf -H "Metadata-Flavor: Google" "${META}/bucket-name")
TOPIC_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/topic-id")
FILE_PREFIX=$(curl -sf -H "Metadata-Flavor: Google" "${META}/file-prefix"    || echo "hw2/")
PORT=$(curl -sf -H "Metadata-Flavor: Google" "${META}/port"                  || echo "80")
SCRIPTS_BUCKET=$(curl -sf -H "Metadata-Flavor: Google" "${META}/scripts-bucket")
DB_NAME=$(curl -sf -H "Metadata-Flavor: Google" "${META}/db-name"            || echo "hw5db")
DB_USER=$(curl -sf -H "Metadata-Flavor: Google" "${META}/db-user"            || echo "hw5user")
DB_PASSWORD=$(curl -sf -H "Metadata-Flavor: Google" "${META}/db-password")
DB_CONN_NAME=$(curl -sf -H "Metadata-Flavor: Google" "${META}/db-conn-name")  # project:region:instance

echo "[startup] PROJECT_ID=${PROJECT_ID}, BUCKET=${BUCKET_NAME}, PORT=${PORT}"
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

# ── Set up Python virtual environment ─────────────────────────────────────────
mkdir -p /opt/service1
python3 -m venv /opt/service1/venv
/opt/service1/venv/bin/pip install --quiet \
    google-cloud-storage \
    google-cloud-logging \
    google-cloud-pubsub \
    "google-auth==2.29.0" \
    pymysql \
    cryptography

# Allow www-data to bind port 80 and own the service directory
chown -R www-data:www-data /opt/service1
PYTHON_BIN=$(readlink -f /opt/service1/venv/bin/python)
setcap 'cap_net_bind_service=+ep' "${PYTHON_BIN}"

# ── Download service1.py and setup_schema.py from GCS ────────────────────────
gcloud storage cp "gs://${SCRIPTS_BUCKET}/hw5-scripts/service1.py"       /opt/service1/service1.py
gcloud storage cp "gs://${SCRIPTS_BUCKET}/hw5-scripts/setup_schema.py"   /opt/service1/setup_schema.py

# ── Run schema setup (wait for proxy to be ready) ────────────────────────────
echo "[startup] Waiting for Cloud SQL Proxy to be ready on 127.0.0.1:3306 ..."
for i in $(seq 1 30); do
    if /opt/service1/venv/bin/python -c \
        "import pymysql; pymysql.connect(host='127.0.0.1',port=3306,user='${DB_USER}',password='${DB_PASSWORD}',connect_timeout=3)" \
        2>/dev/null; then
        echo "  Proxy ready (attempt ${i})."
        break
    fi
    echo "  Not ready yet (attempt ${i}/30), waiting 5s ..."
    sleep 5
done

DB_HOST=127.0.0.1 DB_PORT=3306 DB_NAME="${DB_NAME}" \
DB_USER="${DB_USER}" DB_PASSWORD="${DB_PASSWORD}" \
/opt/service1/venv/bin/python /opt/service1/setup_schema.py

# ── Create environment file for service1 ─────────────────────────────────────
cat > /opt/service1/service1.env <<EOF
PROJECT_ID=${PROJECT_ID}
BUCKET_NAME=${BUCKET_NAME}
TOPIC_ID=${TOPIC_ID}
FILE_PREFIX=${FILE_PREFIX}
PORT=${PORT}
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
EOF

# ── Create systemd service unit for service1 ─────────────────────────────────
cat > /etc/systemd/system/service1.service <<'UNIT'
[Unit]
Description=HW5 Service 1 - Python HTTP Web Server
After=network.target cloud-sql-proxy.service

[Service]
Type=simple
User=www-data
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

systemctl daemon-reload
systemctl enable service1
systemctl start service1

# ── Lock file ────────────────────────────────────────────────────────────────
touch /var/log/startup_already_done
echo "[startup] HW5 Service 1 setup complete and running."
