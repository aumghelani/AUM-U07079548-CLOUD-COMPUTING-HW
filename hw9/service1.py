#!/usr/bin/env python3
"""
HW9 Service 1 - Python HTTP Web Server (runs inside a container on GKE).

Serves files from GCS bucket, logs errors to Cloud Logging,
publishes forbidden-country requests to Pub/Sub (second app reads them).

Port 8080 is used inside the container; the Service exposes 80 externally.
"""

import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

from google.cloud import storage
from google.cloud import logging as gcp_logging
from google.cloud import pubsub_v1

# Config from env (set by Kubernetes Deployment manifest)
BUCKET_NAME = os.environ.get("BUCKET_NAME", "aum-hw2-u07079548")
FILE_PREFIX = os.environ.get("FILE_PREFIX", "hw2/")
PROJECT_ID  = os.environ.get("PROJECT_ID", "u0709548-aum-hw1")
TOPIC_ID    = os.environ.get("TOPIC_ID", "forbidden-requests")
PORT        = int(os.environ.get("PORT", "8080"))

FORBIDDEN_COUNTRIES = {
    "North Korea", "Iran", "Cuba", "Myanmar",
    "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria",
}

log_client = gcp_logging.Client(project=PROJECT_ID)
logger     = log_client.logger("hw9-service1")
gcs_client = storage.Client(project=PROJECT_ID)
publisher  = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)

POD_NAME = os.environ.get("POD_NAME", "unknown")


class Handler(BaseHTTPRequestHandler):

    def do_GET(self):
        # Kubernetes health-check endpoint (used by readiness/liveness probes).
        if self.path == "/health" or self.path == "/healthz":
            self._respond(200, b"OK")
            return

        country = self.headers.get("X-country", "")
        if country in FORBIDDEN_COUNTRIES:
            logger.log_struct(
                {
                    "event":       "FORBIDDEN_COUNTRY",
                    "country":     country,
                    "path":        self.path,
                    "remote_addr": self.client_address[0],
                    "pod":         POD_NAME,
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

        path_parts = self.path.strip("/").split("/")
        file_name  = path_parts[-1] if path_parts and path_parts[-1] else ""

        if not file_name:
            self._respond(400, b"Bad Request: missing file name in path.")
            return

        try:
            bucket = gcs_client.bucket(BUCKET_NAME)
            blob   = bucket.blob(f"{FILE_PREFIX}{file_name}")

            if not blob.exists():
                logger.log_struct(
                    {
                        "event":     "FILE_NOT_FOUND",
                        "file_path": f"{FILE_PREFIX}{file_name}",
                        "bucket":    BUCKET_NAME,
                        "pod":       POD_NAME,
                    },
                    severity="WARNING",
                )
                self._respond(404, b"404 Not Found")
                return

            content = blob.download_as_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("X-Pod-Name", POD_NAME)
            self.end_headers()
            self.wfile.write(content)

        except Exception as exc:
            logger.log_struct(
                {"event": "INTERNAL_ERROR", "error": str(exc), "pod": POD_NAME},
                severity="ERROR",
            )
            self._respond(500, b"500 Internal Server Error")

    def _handle_unsupported(self):
        logger.log_struct(
            {
                "event":  "UNSUPPORTED_METHOD",
                "method": self.command,
                "path":   self.path,
                "pod":    POD_NAME,
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

    def _respond(self, code: int, body: bytes):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Pod-Name", POD_NAME)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    server = ThreadedHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[HW9 Service 1] Pod={POD_NAME} listening on 0.0.0.0:{PORT}", flush=True)
    print(f"[HW9 Service 1] Bucket: gs://{BUCKET_NAME}/{FILE_PREFIX}", flush=True)
    server.serve_forever()
