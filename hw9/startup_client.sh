#!/bin/bash
# startup_client.sh - configures the client VM on first boot.
# Installs Python deps + http_client.py, but does NOT auto-run it
# (the grader / user invokes it explicitly so they can see output).

if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran. Skipping."
    exit 0
fi

set -e
export DEBIAN_FRONTEND=noninteractive
echo "[startup] HW9 Client VM first-time setup ..."

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "${META}/project-id")
SCRIPTS_BUCKET=$(curl -sf -H "Metadata-Flavor: Google" "${META}/scripts-bucket")

apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl

mkdir -p /opt/client
python3 -m venv /opt/client/venv
/opt/client/venv/bin/pip install --quiet \
    "google-cloud-storage==2.19.0" \
    "google-auth==2.29.0"

gcloud storage cp "gs://${SCRIPTS_BUCKET}/hw9-scripts/http_client.py" /opt/client/http_client.py
chmod +x /opt/client/http_client.py

# Shortcut for running it after ssh'ing in:
#   sudo SERVER_HOST=<LB_IP> /opt/client/venv/bin/python /opt/client/http_client.py
cat > /etc/profile.d/hw9_client.sh <<'EOF'
export HW9_CLIENT=/opt/client/http_client.py
export HW9_PY=/opt/client/venv/bin/python
echo "HW9 client ready. Run:"
echo "  SERVER_HOST=<LB_IP> \$HW9_PY \$HW9_CLIENT"
EOF

touch /var/log/startup_already_done
echo "[startup] HW9 Client VM ready."
