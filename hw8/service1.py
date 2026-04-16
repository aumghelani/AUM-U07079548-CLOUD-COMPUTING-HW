#!/usr/bin/env python3
"""
HW8 Service 1 - Python HTTP Web Server on GCP VM (behind Load Balancer)
Serves files from GCS bucket, logs errors to Cloud Logging,
publishes forbidden-country requests to Pub/Sub.
Returns the VM's zone as the X-Server-Zone response header.
"""

import json
import os
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

from google.cloud import storage
from google.cloud import logging as gcp_logging
from google.cloud import pubsub_v1

# ── Configuration (from environment variables set by startup script) ──────────
BUCKET_NAME = os.environ.get("BUCKET_NAME", "aum-hw2-u07079548")
FILE_PREFIX = os.environ.get("FILE_PREFIX", "hw2/")
PROJECT_ID  = os.environ.get("PROJECT_ID", "u0709548-aum-hw1")
TOPIC_ID    = os.environ.get("TOPIC_ID", "forbidden-requests")
PORT        = int(os.environ.get("PORT", "80"))

FORBIDDEN_COUNTRIES = {
    "North Korea", "Iran", "Cuba", "Myanmar",
    "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria",
}

# ── Fetch VM zone from GCE metadata server ───────────────────────────────────
def get_vm_zone():
    """Query the GCE metadata server for this VM's zone."""
    url = "http://metadata.google.internal/computeMetadata/v1/instance/zone"
    req = urllib.request.Request(url, headers={"Metadata-Flavor": "Google"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            # Returns something like "projects/123456/zones/us-central1-a"
            full_zone = resp.read().decode().strip()
            return full_zone.split("/")[-1]  # e.g. "us-central1-a"
    except Exception:
        return "unknown"

VM_ZONE = get_vm_zone()

# ── Initialize GCP clients once at module level ───────────────────────────────
log_client = gcp_logging.Client(project=PROJECT_ID)
logger     = log_client.logger("hw8-service1")
gcs_client = storage.Client(project=PROJECT_ID)
publisher  = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)


class Handler(BaseHTTPRequestHandler):

    def do_GET(self):
        # Handle health check requests from the load balancer
        if self.path == "/health":
            self._respond(200, b"OK", extra_headers=True)
            return

        # 1. Export-control check
        country = self.headers.get("X-country", "")
        if country in FORBIDDEN_COUNTRIES:
            logger.log_struct(
                {
                    "event":       "FORBIDDEN_COUNTRY",
                    "country":     country,
                    "path":        self.path,
                    "remote_addr": self.client_address[0],
                    "zone":        VM_ZONE,
                },
                severity="CRITICAL",
            )
            try:
                msg = json.dumps({
                    "country":        country,
                    "file_requested": self.path,
                    "remote_addr":    self.client_address[0],
                }).encode()
                publisher.publish(topic_path, msg)
            except Exception as pub_err:
                logger.log_struct(
                    {"event": "PUBSUB_FAILED", "error": str(pub_err)},
                    severity="WARNING",
                )
            self._respond(403, b"Forbidden: export restrictions apply.")
            return

        # 2. Extract filename from URL path
        path_parts = self.path.strip("/").split("/")
        file_name  = path_parts[-1] if path_parts and path_parts[-1] else ""

        if not file_name:
            self._respond(400, b"Bad Request: missing file name in path.")
            return

        # 3. Serve file from GCS
        try:
            bucket = gcs_client.bucket(BUCKET_NAME)
            blob   = bucket.blob(f"{FILE_PREFIX}{file_name}")

            if not blob.exists():
                logger.log_struct(
                    {
                        "event":     "FILE_NOT_FOUND",
                        "file_path": f"{FILE_PREFIX}{file_name}",
                        "bucket":    BUCKET_NAME,
                        "zone":      VM_ZONE,
                    },
                    severity="WARNING",
                )
                self._respond(404, b"404 Not Found")
                return

            content = blob.download_as_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("X-Server-Zone", VM_ZONE)
            self.end_headers()
            self.wfile.write(content)

        except Exception as exc:
            logger.log_struct(
                {"event": "INTERNAL_ERROR", "error": str(exc), "zone": VM_ZONE},
                severity="ERROR",
            )
            self._respond(500, b"500 Internal Server Error")

    # ── All other methods return 501 ─────────────────────────────────────────
    def _handle_unsupported(self):
        logger.log_struct(
            {
                "event":  "UNSUPPORTED_METHOD",
                "method": self.command,
                "path":   self.path,
                "zone":   VM_ZONE,
            },
            severity="WARNING",
        )
        self._respond(501, b"501 Not Implemented")

    do_POST    = _handle_unsupported
    do_PUT     = _handle_unsupported
    do_DELETE  = _handle_unsupported
    do_HEAD    = _handle_unsupported
    do_OPTIONS = _handle_unsupported
    do_PATCH   = _handle_unsupported
    do_CONNECT = _handle_unsupported
    do_TRACE   = _handle_unsupported

    # ── Helpers ──────────────────────────────────────────────────────────────
    def _respond(self, code: int, body: bytes, extra_headers: bool = False):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Server-Zone", VM_ZONE)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Suppress default access log to stdout (Cloud Logging handles it)
        pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle each request in its own thread."""
    daemon_threads = True


if __name__ == "__main__":
    server = ThreadedHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[Service 1] Listening on 0.0.0.0:{PORT}", flush=True)
    print(f"[Service 1] Zone: {VM_ZONE}", flush=True)
    print(f"[Service 1] Bucket: gs://{BUCKET_NAME}/{FILE_PREFIX}", flush=True)
    server.serve_forever()
