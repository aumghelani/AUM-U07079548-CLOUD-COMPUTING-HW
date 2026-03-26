#!/usr/bin/env python3
"""
HW5 Service 1 - Python HTTP Web Server on GCP VM
Serves files from GCS bucket, logs errors to Cloud Logging,
publishes forbidden-country requests to Pub/Sub,
and records all request metadata to Cloud SQL (MySQL).
Instrumented with high-accuracy timing per operation.
"""

import json
import os
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

import pymysql
import pymysql.cursors

from google.cloud import storage
from google.cloud import logging as gcp_logging
from google.cloud import pubsub_v1

# ── Configuration (from environment variables set by startup script) ──────────
BUCKET_NAME  = os.environ.get("BUCKET_NAME", "aum-hw2-u07079548")
FILE_PREFIX  = os.environ.get("FILE_PREFIX", "hw2/")
PROJECT_ID   = os.environ.get("PROJECT_ID", "")
TOPIC_ID     = os.environ.get("TOPIC_ID", "forbidden-requests")
PORT         = int(os.environ.get("PORT", "80"))

# Cloud SQL (MySQL) via Unix socket (Cloud SQL Auth Proxy on same VM)
DB_HOST      = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT      = int(os.environ.get("DB_PORT", "3306"))
DB_NAME      = os.environ.get("DB_NAME", "hw5db")
DB_USER      = os.environ.get("DB_USER", "hw5user")
DB_PASSWORD  = os.environ.get("DB_PASSWORD", "")
DB_SOCKET    = os.environ.get("DB_SOCKET", "")   # e.g. /cloudsql/<conn-name>

FORBIDDEN_COUNTRIES = {
    "North Korea", "Iran", "Cuba", "Myanmar",
    "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria",
}

# ── Initialize GCP clients once at module level ───────────────────────────────
log_client = gcp_logging.Client(project=PROJECT_ID)
logger     = log_client.logger("hw5-service1")
gcs_client = storage.Client(project=PROJECT_ID)
publisher  = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)


# ── Database helpers ──────────────────────────────────────────────────────────
def get_db_connection():
    """Open a new pymysql connection (called per-request for simplicity)."""
    kwargs = dict(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )
    if DB_SOCKET:
        kwargs["unix_socket"] = DB_SOCKET
        del kwargs["host"]
        del kwargs["port"]
    return pymysql.connect(**kwargs)


def insert_request(conn, country, client_ip, gender, age, income,
                   is_banned, time_of_day, requested_file):
    """Insert a successful (or any non-error) request row into requests table."""
    sql = """
        INSERT INTO requests
            (country, client_ip, gender, age, income,
             is_banned, time_of_day, requested_file)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
    """
    t0 = time.perf_counter_ns()
    with conn.cursor() as cur:
        cur.execute(sql, (country, client_ip, gender, age, income,
                          is_banned, time_of_day, requested_file))
    elapsed_ns = time.perf_counter_ns() - t0
    return elapsed_ns


def insert_error(conn, requested_file, error_code):
    """Insert a failed-request row into errors table."""
    sql = """
        INSERT INTO errors (requested_file, error_code)
        VALUES (%s, %s)
    """
    t0 = time.perf_counter_ns()
    with conn.cursor() as cur:
        cur.execute(sql, (requested_file, error_code))
    elapsed_ns = time.perf_counter_ns() - t0
    return elapsed_ns


# ── Request handler ───────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):

    # ── Timed sub-operations ─────────────────────────────────────────────────

    def extract_headers(self):
        """Extract and return request metadata from HTTP headers. Returns dict + elapsed ns."""
        t0 = time.perf_counter_ns()
        data = {
            "country":        self.headers.get("X-country", ""),
            "client_ip":      self.headers.get("X-client-IP",
                                self.client_address[0]),
            "gender":         self.headers.get("X-gender", ""),
            "age":            self.headers.get("X-age", ""),
            "income":         self.headers.get("X-income", ""),
            "time_of_day":    self.headers.get("X-time", ""),
        }
        elapsed_ns = time.perf_counter_ns() - t0
        return data, elapsed_ns

    def read_file_from_gcs(self, file_name):
        """Download file bytes from GCS. Returns (content_bytes_or_None, status_code, elapsed_ns)."""
        t0 = time.perf_counter_ns()
        try:
            bucket = gcs_client.bucket(BUCKET_NAME)
            blob   = bucket.blob(f"{FILE_PREFIX}{file_name}")
            if not blob.exists():
                elapsed_ns = time.perf_counter_ns() - t0
                return None, 404, elapsed_ns
            content = blob.download_as_bytes()
            elapsed_ns = time.perf_counter_ns() - t0
            return content, 200, elapsed_ns
        except Exception as exc:
            elapsed_ns = time.perf_counter_ns() - t0
            logger.log_struct({"event": "GCS_ERROR", "error": str(exc)}, severity="ERROR")
            return None, 500, elapsed_ns

    def send_response_body(self, code, body, content_type="text/html; charset=utf-8"):
        """Send HTTP response with timing. Returns elapsed_ns."""
        t0 = time.perf_counter_ns()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        elapsed_ns = time.perf_counter_ns() - t0
        return elapsed_ns

    # ── Main GET handler ─────────────────────────────────────────────────────

    def do_GET(self):
        request_time = datetime.now(timezone.utc)

        # 1. Extract headers ──────────────────────────────────────────────────
        meta, t_headers = self.extract_headers()
        country      = meta["country"]
        client_ip    = meta["client_ip"]
        gender       = meta["gender"]
        age          = meta["age"]
        income       = meta["income"]
        time_of_day  = meta["time_of_day"]
        is_banned    = 1 if country in FORBIDDEN_COUNTRIES else 0

        # 2. Extract filename from URL ─────────────────────────────────────────
        path_parts = self.path.strip("/").split("/")
        file_name  = path_parts[-1] if path_parts and path_parts[-1] else ""

        # ── Open DB connection ────────────────────────────────────────────────
        conn = None
        try:
            conn = get_db_connection()
        except Exception as db_err:
            logger.log_struct({"event": "DB_CONNECT_ERROR", "error": str(db_err)},
                              severity="ERROR")

        # 3. Forbidden-country check ───────────────────────────────────────────
        if is_banned:
            logger.log_struct(
                {"event": "FORBIDDEN_COUNTRY", "country": country,
                 "path": self.path, "remote_addr": client_ip},
                severity="CRITICAL",
            )
            try:
                msg = json.dumps({
                    "country": country, "file_requested": self.path,
                    "remote_addr": client_ip,
                }).encode()
                publisher.publish(topic_path, msg)
            except Exception as pub_err:
                logger.log_struct({"event": "PUBSUB_FAILED", "error": str(pub_err)},
                                  severity="WARNING")

            t_send = self.send_response_body(403, b"Forbidden: export restrictions apply.")

            # Log to DB ────────────────────────────────────────────────────────
            t_db = 0
            if conn:
                try:
                    t_db = insert_request(conn, country, client_ip, gender, age,
                                          income, is_banned,
                                          time_of_day, self.path)
                    insert_error(conn, self.path, 403)
                except Exception as e:
                    logger.log_struct({"event": "DB_INSERT_ERROR", "error": str(e)},
                                      severity="ERROR")
                finally:
                    conn.close()

            self._log_timing(t_headers, 0, t_send, t_db)
            return

        # 4. Missing filename ──────────────────────────────────────────────────
        if not file_name:
            t_send = self.send_response_body(400, b"Bad Request: missing file name.")
            t_db = 0
            if conn:
                try:
                    t_db = insert_error(conn, self.path, 400)
                except Exception as e:
                    logger.log_struct({"event": "DB_INSERT_ERROR", "error": str(e)},
                                      severity="ERROR")
                finally:
                    conn.close()
            self._log_timing(t_headers, 0, t_send, t_db)
            return

        # 5. Read file from GCS ────────────────────────────────────────────────
        content, status, t_gcs = self.read_file_from_gcs(file_name)

        if status != 200:
            body = b"404 Not Found" if status == 404 else b"500 Internal Server Error"
            if status == 404:
                logger.log_struct(
                    {"event": "FILE_NOT_FOUND",
                     "file_path": f"{FILE_PREFIX}{file_name}",
                     "bucket": BUCKET_NAME},
                    severity="WARNING",
                )
            t_send = self.send_response_body(status, body)
            t_db = 0
            if conn:
                try:
                    t_db = insert_error(conn, self.path, status)
                except Exception as e:
                    logger.log_struct({"event": "DB_INSERT_ERROR", "error": str(e)},
                                      severity="ERROR")
                finally:
                    conn.close()
            self._log_timing(t_headers, t_gcs, t_send, t_db)
            return

        # 6. Send successful response ──────────────────────────────────────────
        t_send = self.send_response_body(200, content)

        # 7. Insert into requests table ────────────────────────────────────────
        t_db = 0
        if conn:
            try:
                t_db = insert_request(conn, country, client_ip, gender, age,
                                      income, is_banned,
                                      time_of_day, self.path)
            except Exception as e:
                logger.log_struct({"event": "DB_INSERT_ERROR", "error": str(e)},
                                  severity="ERROR")
            finally:
                conn.close()

        self._log_timing(t_headers, t_gcs, t_send, t_db)

    # ── Timing logger ────────────────────────────────────────────────────────
    def _log_timing(self, t_headers_ns, t_gcs_ns, t_send_ns, t_db_ns):
        """Log per-operation timings (nanoseconds → milliseconds) to Cloud Logging."""
        logger.log_struct(
            {
                "event":           "REQUEST_TIMING",
                "headers_ms":      t_headers_ns / 1e6,
                "gcs_read_ms":     t_gcs_ns    / 1e6,
                "send_response_ms": t_send_ns  / 1e6,
                "db_insert_ms":    t_db_ns     / 1e6,
            },
            severity="INFO",
        )

    # ── Unsupported methods ──────────────────────────────────────────────────
    def _handle_unsupported(self):
        logger.log_struct(
            {"event": "UNSUPPORTED_METHOD", "method": self.command, "path": self.path},
            severity="WARNING",
        )
        self.send_response_body(501, b"501 Not Implemented")

    do_POST    = _handle_unsupported
    do_PUT     = _handle_unsupported
    do_DELETE  = _handle_unsupported
    do_HEAD    = _handle_unsupported
    do_OPTIONS = _handle_unsupported
    do_PATCH   = _handle_unsupported
    do_CONNECT = _handle_unsupported
    do_TRACE   = _handle_unsupported

    def log_message(self, format, *args):
        pass  # suppress default stdout access log


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle each request in its own thread."""
    daemon_threads = True


if __name__ == "__main__":
    server = ThreadedHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[Service 1] Listening on 0.0.0.0:{PORT}", flush=True)
    print(f"[Service 1] Bucket: gs://{BUCKET_NAME}/{FILE_PREFIX}", flush=True)
    print(f"[Service 1] DB: {DB_NAME}@{DB_HOST}:{DB_PORT}", flush=True)
    server.serve_forever()
