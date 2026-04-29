#!/usr/bin/env python3
"""
HW9 Service 2 - Forbidden-country reporter.

Runs on a VM (not on GKE). Subscribes to the forbidden-requests Pub/Sub
topic and prints one alert line per forbidden request the GKE web server
receives.
"""

import json
import os
from datetime import datetime, timezone

from google.cloud import pubsub_v1

PROJECT_ID      = os.environ.get("PROJECT_ID", "u0709548-aum-hw1")
SUBSCRIPTION_ID = os.environ.get("SUBSCRIPTION_ID", "forbidden-requests-sub")


def callback(message: pubsub_v1.subscriber.message.Message):
    try:
        data    = json.loads(message.data.decode("utf-8"))
        country = data.get("country", "unknown")
        file_r  = data.get("file_requested", "(none)")
        remote  = data.get("remote_addr", "unknown")
        ts      = datetime.now(timezone.utc).isoformat()

        print(
            f"[{ts}] FORBIDDEN REQUEST -- "
            f"country={country}, file={file_r}, remote_addr={remote}",
            flush=True,
        )
    except Exception as exc:
        print(f"[ERROR] Failed to process message: {exc}", flush=True)
    finally:
        message.ack()


def main():
    subscriber        = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)

    print(f"[HW9 Service 2] Listening on {subscription_path} ...", flush=True)
    streaming_pull = subscriber.subscribe(subscription_path, callback=callback)
    try:
        streaming_pull.result()
    except KeyboardInterrupt:
        streaming_pull.cancel()
        streaming_pull.result()
        print("[HW9 Service 2] Stopped.")


if __name__ == "__main__":
    main()
