#!/usr/bin/env python3
"""
HW9 HTTP Client - requests a few hundred files from the GKE Service.
Intended to run on a VM (step 4 of the HW9 spec).

Env:
  SERVER_HOST     external IP of the GKE LoadBalancer Service (required)
  SERVER_PORT     default 80
  BUCKET_NAME     default aum-hw2-u07079548
  FILE_PREFIX     default hw2/
  MAX_FILES       default 300
  INCLUDE_FORBIDDEN  "1" = send ~10% requests from forbidden countries
"""

import http.client
import os
import random
import sys
import time

from google.cloud import storage

SERVER_HOST = os.environ.get("SERVER_HOST", "")
SERVER_PORT = int(os.environ.get("SERVER_PORT", "80"))
BUCKET_NAME = os.environ.get("BUCKET_NAME", "aum-hw2-u07079548")
FILE_PREFIX = os.environ.get("FILE_PREFIX", "hw2/")
MAX_FILES   = int(os.environ.get("MAX_FILES", "300"))
INCLUDE_FORBIDDEN = os.environ.get("INCLUDE_FORBIDDEN", "1") == "1"

FORBIDDEN = ["North Korea", "Iran", "Cuba", "Myanmar",
             "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria"]
ALLOWED   = ["United States", "India", "Germany", "Japan",
             "Brazil", "France", "Canada", "Australia"]


def get_file_list() -> list[str]:
    client = storage.Client()
    blobs  = client.list_blobs(BUCKET_NAME, prefix=FILE_PREFIX,
                               max_results=MAX_FILES + 1)
    names  = [b.name[len(FILE_PREFIX):] for b in blobs
              if b.name != FILE_PREFIX and b.name[len(FILE_PREFIX):]]
    return names[:MAX_FILES]


def request_file(conn, filename, country):
    conn.request("GET", f"/{filename}", headers={"X-country": country})
    resp = conn.getresponse()
    body = resp.read()
    return resp.status, len(body)


def main():
    if not SERVER_HOST:
        print("ERROR: SERVER_HOST env var required (GKE Service external IP).")
        sys.exit(1)

    print(f"[HW9 Client] Target {SERVER_HOST}:{SERVER_PORT}")

    files = get_file_list()
    if not files:
        print("[HW9 Client] Bucket empty, exiting.")
        sys.exit(1)

    print(f"[HW9 Client] Sending {len(files)} requests "
          f"(include_forbidden={INCLUDE_FORBIDDEN}) ...")

    random.seed(42)
    counts = {}
    start  = time.perf_counter()
    conn   = http.client.HTTPConnection(SERVER_HOST, SERVER_PORT, timeout=30)

    for i, fname in enumerate(files):
        # Pick a country: ~10% forbidden if enabled.
        if INCLUDE_FORBIDDEN and random.random() < 0.10:
            country = random.choice(FORBIDDEN)
        else:
            country = random.choice(ALLOWED)

        try:
            status, size = request_file(conn, fname, country)
            counts[status] = counts.get(status, 0) + 1
            if i < 20 or i % 50 == 0:
                print(f"  [{status}] GET /{fname} ({country}) -> {size} bytes")
        except Exception as exc:
            counts["ERR"] = counts.get("ERR", 0) + 1
            print(f"  [ERR] GET /{fname} -> {exc}")
            try: conn.close()
            except Exception: pass
            conn = http.client.HTTPConnection(SERVER_HOST, SERVER_PORT, timeout=30)

    try: conn.close()
    except Exception: pass

    elapsed = time.perf_counter() - start
    print(f"\n[HW9 Client] Done in {elapsed:.2f}s "
          f"({len(files) / elapsed:.1f} req/s)")
    print("[HW9 Client] Status breakdown:")
    for k, v in sorted(counts.items(), key=lambda x: str(x[0])):
        print(f"    {k}: {v}")


if __name__ == "__main__":
    main()
