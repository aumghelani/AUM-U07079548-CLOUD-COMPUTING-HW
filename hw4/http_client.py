#!/usr/bin/env python3
"""
HW4 HTTP Client - Requests up to 100 files from Service 1.
Run on VM2 (the client VM), not on the server VM.

Usage:
    SERVER_HOST=<static-ip> python3 http_client.py
    SERVER_HOST=<static-ip> SERVER_PORT=80 python3 http_client.py
"""

import http.client
import os
import sys
import time

from google.cloud import storage

# ── Configuration ─────────────────────────────────────────────────────────────
SERVER_HOST  = os.environ.get("SERVER_HOST", "")
SERVER_PORT  = int(os.environ.get("SERVER_PORT", "80"))
BUCKET_NAME  = os.environ.get("BUCKET_NAME", "aum-hw2-u07079548")
FILE_PREFIX  = os.environ.get("FILE_PREFIX", "hw2/")
MAX_FILES    = int(os.environ.get("MAX_FILES", "100"))


def get_file_list() -> list[str]:
    """List up to MAX_FILES files in the GCS bucket under FILE_PREFIX."""
    client = storage.Client()
    blobs  = client.list_blobs(BUCKET_NAME, prefix=FILE_PREFIX, max_results=MAX_FILES + 1)
    names  = [
        b.name[len(FILE_PREFIX):]   # strip prefix, keep only filename
        for b in blobs
        if b.name != FILE_PREFIX and b.name[len(FILE_PREFIX):]  # skip the prefix "folder" entry
    ]
    return names[:MAX_FILES]


def request_file(conn: http.client.HTTPConnection, filename: str) -> tuple[int, int]:
    conn.request("GET", f"/{filename}")
    resp = conn.getresponse()
    body = resp.read()
    return resp.status, len(body)


def main():
    if not SERVER_HOST:
        print("Error: SERVER_HOST environment variable is required.")
        print("  Usage: SERVER_HOST=<server-ip> python3 http_client.py")
        sys.exit(1)

    print(f"[Client] Target server: {SERVER_HOST}:{SERVER_PORT}")

    files = get_file_list()
    if not files:
        print("[Client] No files found in bucket. Exiting.")
        sys.exit(1)

    print(f"[Client] Requesting {len(files)} files ...")

    success = fail = 0
    start   = time.perf_counter()

    conn = http.client.HTTPConnection(SERVER_HOST, SERVER_PORT, timeout=30)
    for fname in files:
        try:
            status, size = request_file(conn, fname)
            marker = "OK" if status == 200 else "FAIL"
            print(f"  [{marker}] GET /{fname} -> HTTP {status} ({size} bytes)")
            if status == 200:
                success += 1
            else:
                fail += 1
        except Exception as exc:
            print(f"  [ERR] GET /{fname} -> {exc}")
            fail += 1
            # Reconnect on connection error
            try:
                conn.close()
            except Exception:
                pass
            conn = http.client.HTTPConnection(SERVER_HOST, SERVER_PORT, timeout=30)

    try:
        conn.close()
    except Exception:
        pass

    elapsed = time.perf_counter() - start
    print(f"\n[Client] Done: {success} success, {fail} failed in {elapsed:.2f}s")
    print(f"[Client] Throughput: {len(files) / elapsed:.1f} req/s")


if __name__ == "__main__":
    main()
