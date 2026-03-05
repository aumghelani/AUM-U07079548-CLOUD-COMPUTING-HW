import json
import functions_framework
from google.cloud import storage, logging as gcp_logging
from google.cloud import pubsub_v1

# ── Configuration ────────────────────────────────────────────────────────────
BUCKET_NAME       = "aum-hw2-u07079548"
FILE_PREFIX       = "hw2/"
PUBSUB_PROJECT_ID = "U0709548-AUM-HW1"
PUBSUB_TOPIC_ID   = "forbidden-requests"

FORBIDDEN_COUNTRIES = {
    "North Korea", "Iran", "Cuba", "Myanmar",
    "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria"
}

# ── Module-level clients (reused across invocations) ─────────────────────────
log_client  = gcp_logging.Client()
logger      = log_client.logger("hw3-service1")

publisher   = pubsub_v1.PublisherClient()
topic_path  = publisher.topic_path(PUBSUB_PROJECT_ID, PUBSUB_TOPIC_ID)

gcs_client  = storage.Client()          # initialized once, not per-request


# ── Helper: structured log ────────────────────────────────────────────────────
def log_error(event_type: str, details: dict):
    """Print a JSON-formatted structured log (auto-ingested by Cloud Logging)."""
    payload = {"severity": "ERROR", "event": event_type, **details}
    # Commented out to avoid blocking API call that causes timeouts
    # logger.log_struct(payload, severity="ERROR")
    print(json.dumps(payload))          # Cloud Logging parses JSON prints as structured logs


# ── Helper: publish to Pub/Sub ────────────────────────────────────────────────
def publish_forbidden(country: str, file_requested: str, remote_addr: str):
    message = {
        "country":        country,
        "file_requested": file_requested or "(none)",
        "remote_addr":    remote_addr,
    }
    data = json.dumps(message).encode("utf-8")
    publisher.publish(topic_path, data)  # fire-and-forget, no .result() to avoid blocking


# ── Main entry point ──────────────────────────────────────────────────────────
@functions_framework.http
def handle_request(request):
    """HTTP Cloud Function – Service 1."""

    # ── 1. Reject non-GET methods with 501 ───────────────────────────────────
    if request.method != "GET":
        log_error("UNSUPPORTED_METHOD", {
            "method": request.method,
            "path":   request.path,
        })
        return ("Method Not Implemented", 501)

    # Accept filename from ?file= query param OR from URL path (/hw2/filename.html)
    file_name = request.args.get("file", "")
    if not file_name:
        # Extract last segment of path, e.g. /hw2/33812.html → 33812.html
        path_parts = request.path.strip("/").split("/")
        file_name = path_parts[-1] if path_parts and path_parts[-1] else ""

    # ── 2. Export-control check (X-country header) → 400 + Pub/Sub ───────────
    country = request.headers.get("X-country", "")
    if country in FORBIDDEN_COUNTRIES:
        log_error("FORBIDDEN_COUNTRY", {
            "country":        country,
            "file_requested": file_name,
            "remote_addr":    request.remote_addr,
        })
        try:
            publish_forbidden(country, file_name, request.remote_addr)
        except Exception as pub_err:
            print(json.dumps({"severity": "WARNING", "event": "PUBSUB_FAILED", "error": str(pub_err)}))
        return ("Permission Denied: export restrictions apply.", 400)

    # ── 3. Require a file parameter ───────────────────────────────────────────
    if not file_name:
        return ("Missing 'file' query parameter.", 400)

    # ── 4. Serve file from GCS ────────────────────────────────────────────────
    try:
        bucket = gcs_client.bucket(BUCKET_NAME)
        blob   = bucket.blob(f"{FILE_PREFIX}{file_name}")

        if not blob.exists():
            log_error("FILE_NOT_FOUND", {
                "bucket":    BUCKET_NAME,
                "file_path": f"{FILE_PREFIX}{file_name}",
            })
            return ("File Not Found", 404)

        content = blob.download_as_text()
        return (content, 200)

    except Exception as exc:
        print(json.dumps({"severity": "ERROR", "event": "UNEXPECTED_ERROR", "error": str(exc)}))
        return (f"Internal Server Error: {exc}", 500)
