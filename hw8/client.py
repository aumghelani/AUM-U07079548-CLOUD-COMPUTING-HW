#!/usr/bin/env python3
"""
HW8 Client - Sends requests to the load balancer once per second,
prints the X-Server-Zone header to show which backend VM is responding.
Tracks zone counts and reports the ratio at the end.

Usage:
    python3 client.py <LOAD_BALANCER_IP> [DURATION_SECONDS]

Examples:
    python3 client.py 34.56.78.90          # run for 60 seconds (default)
    python3 client.py 34.56.78.90 120      # run for 120 seconds
"""

import http.client
import sys
import time
from collections import Counter

# ── Configuration ─────────────────────────────────────────────────────────────
DEFAULT_DURATION = 60   # seconds
PORT = 80
# Request a known file from the HW2 bucket (0.html always exists)
REQUEST_PATH = "/0.html"


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 client.py <LOAD_BALANCER_IP> [DURATION_SECONDS]")
        sys.exit(1)

    lb_ip = sys.argv[1]
    duration = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_DURATION

    print(f"[Client] Target: {lb_ip}:{PORT}")
    print(f"[Client] Duration: {duration}s (1 request/second)")
    print(f"[Client] Requesting: GET {REQUEST_PATH}")
    print("-" * 70)

    zone_counts = Counter()
    error_count = 0
    total_requests = 0
    start_time = time.time()

    while time.time() - start_time < duration:
        total_requests += 1
        req_time = time.strftime("%H:%M:%S")
        try:
            conn = http.client.HTTPConnection(lb_ip, PORT, timeout=5)
            conn.request("GET", REQUEST_PATH)
            resp = conn.getresponse()
            resp.read()  # consume body

            zone = resp.getheader("X-Server-Zone", "unknown")
            status = resp.status
            conn.close()

            zone_counts[zone] += 1
            print(f"  [{req_time}] HTTP {status} | Zone: {zone}")

        except Exception as exc:
            error_count += 1
            print(f"  [{req_time}] ERROR: {exc}")

        # Sleep until the next 1-second mark
        elapsed = time.time() - start_time
        next_tick = total_requests  # we want request N at second N
        sleep_time = next_tick - elapsed
        if sleep_time > 0:
            time.sleep(sleep_time)

    # ── Summary ──────────────────────────────────────────────────────────────
    print("-" * 70)
    print(f"\n[Client] Summary after {duration}s:")
    print(f"  Total requests : {total_requests}")
    print(f"  Errors         : {error_count}")
    print(f"\n  Zone distribution:")
    for zone, count in sorted(zone_counts.items()):
        pct = (count / total_requests) * 100
        print(f"    {zone}: {count} requests ({pct:.1f}%)")

    if error_count > 0:
        pct = (error_count / total_requests) * 100
        print(f"    ERRORS: {error_count} ({pct:.1f}%)")

    print(f"\n  Ratio: ", end="")
    zones = sorted(zone_counts.keys())
    if len(zones) == 2:
        a, b = zones
        print(f"{a}:{zone_counts[a]}  vs  {b}:{zone_counts[b]}")
    elif len(zones) == 1:
        z = zones[0]
        print(f"All requests served by {z} ({zone_counts[z]} total)")
    else:
        print(f"{dict(zone_counts)}")


if __name__ == "__main__":
    main()
