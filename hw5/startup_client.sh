#!/bin/bash
# startup_client.sh - Configures a client VM on first boot.
# This VM is used to run the provided http-client binary against the web server.

# ── Run-once guard ────────────────────────────────────────────────────────────
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran. Skipping."
    exit 0
fi

set -e
export DEBIAN_FRONTEND=noninteractive
echo "[startup] Setting up client VM ..."

# ── Read instance metadata ────────────────────────────────────────────────────
META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
SCRIPTS_BUCKET=$(curl -sf -H "Metadata-Flavor: Google" "${META}/scripts-bucket")
SERVER_HOST=$(curl -sf -H "Metadata-Flavor: Google" "${META}/server-host")
RANDOM_SEED=$(curl -sf -H "Metadata-Flavor: Google" "${META}/random-seed" || echo "42")
NUM_REQUESTS=$(curl -sf -H "Metadata-Flavor: Google" "${META}/num-requests" || echo "50000")
FILE_INDEX=$(curl -sf -H "Metadata-Flavor: Google" "${META}/file-index" || echo "20000")

# ── Install dependencies ──────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl wget

# ── Download the http-client Linux binary from GCS ───────────────────────────
mkdir -p /opt/client
gcloud storage cp "gs://${SCRIPTS_BUCKET}/hw5-scripts/http-client" /opt/client/http-client
chmod +x /opt/client/http-client

# ── Write a convenience run script ───────────────────────────────────────────
cat > /opt/client/run_client.sh <<EOF
#!/bin/bash
# Run the HTTP client: 50,000 requests with fixed random seed
/opt/client/http-client \\
    -d ${SERVER_HOST} \\
    -b none \\
    -w none \\
    -n ${NUM_REQUESTS} \\
    -i ${FILE_INDEX} \\
    -p 80 \\
    -r ${RANDOM_SEED}
EOF
chmod +x /opt/client/run_client.sh

touch /var/log/startup_already_done
echo "[startup] Client VM setup complete."
echo "[startup] Run: bash /opt/client/run_client.sh"
