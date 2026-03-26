#!/usr/bin/env python3
"""
HW4 Service 2 - Forbidden Country Reporter on GCP VM
Subscribes to the forbidden-requests Pub/Sub topic and prints alerts.
Runs on VM3 using the VM's attached service account (ADC).
"""

import json
import os
from datetime import datetime, timezone

from google.cloud import pubsub_v1

# ── Configuration (from environment variables set by startup script) ──────────
PROJECT_ID       = os.environ.get("PROJECT_ID", "")
SUBSCRIPTION_ID  = os.environ.get("SUBSCRIPTION_ID", "forbidden-requests-sub")


def callback(message: pubsub_v1.subscriber.message.Message):
    try:
        data    = json.loads(message.data.decode("utf-8"))
        country = data.get("country", "unknown")
        file_r  = data.get("file_requested", "(none)")
        remote  = data.get("remote_addr", "unknown")
        ts      = datetime.now(timezone.utc).isoformat()

        log_line = (
            f"[{ts}] FORBIDDEN REQUEST -- "
            f"country={country}, file={file_r}, remote_addr={remote}"
        )
        print(log_line, flush=True)

    except Exception as exc:
        print(f"[ERROR] Failed to process message: {exc}", flush=True)
    finally:
        message.ack()


def main():
    subscriber        = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)

    print(f"[Service 2] Listening on {subscription_path} ...", flush=True)
    streaming_pull = subscriber.subscribe(subscription_path, callback=callback)

    try:
        streaming_pull.result()
    except KeyboardInterrupt:
        streaming_pull.cancel()
        streaming_pull.result()
        print("[Service 2] Stopped.")


if __name__ == "__main__":
    main()
