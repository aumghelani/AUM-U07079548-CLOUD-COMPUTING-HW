"""
Cloud Function: stop_idle_db
Runs every hour via Cloud Scheduler.
Stops the Cloud SQL instance if it is currently RUNNABLE (running)
during off-hours, so it does not waste credits.
"""

import os
import functions_framework
from googleapiclient import discovery
from googleapiclient.errors import HttpError


PROJECT_ID  = os.environ.get("PROJECT_ID", "")
INSTANCE_ID = os.environ.get("INSTANCE_ID", "hw5-mysql")

# Define the hours (UTC, 24h) during which the DB is ALLOWED to run.
# Outside these hours the function will stop it.
ALLOWED_START_HOUR = int(os.environ.get("ALLOWED_START_HOUR", "12"))  # noon UTC
ALLOWED_END_HOUR   = int(os.environ.get("ALLOWED_END_HOUR",   "3"))   # 3 AM UTC next day


@functions_framework.http
def stop_idle_db(request):
    """HTTP-triggered Cloud Function (also works as a background function)."""
    from datetime import datetime, timezone

    now_hour = datetime.now(timezone.utc).hour

    # Determine if we're inside the allowed window (handles wrap-around midnight)
    if ALLOWED_START_HOUR <= ALLOWED_END_HOUR:
        in_window = ALLOWED_START_HOUR <= now_hour < ALLOWED_END_HOUR
    else:
        # window wraps midnight: e.g. 12 -> 3 means 12..23 or 0..2
        in_window = now_hour >= ALLOWED_START_HOUR or now_hour < ALLOWED_END_HOUR

    if in_window:
        msg = (f"[stop_idle_db] Hour={now_hour} UTC is within allowed window "
               f"({ALLOWED_START_HOUR}–{ALLOWED_END_HOUR}). DB left running.")
        print(msg)
        return msg, 200

    # Check current state of the instance
    sqladmin = discovery.build("sqladmin", "v1beta4")
    try:
        inst = sqladmin.instances().get(
            project=PROJECT_ID, instance=INSTANCE_ID
        ).execute()
    except HttpError as e:
        msg = f"[stop_idle_db] ERROR getting instance state: {e}"
        print(msg)
        return msg, 500

    state = inst.get("state", "UNKNOWN")
    print(f"[stop_idle_db] Instance '{INSTANCE_ID}' state={state}")

    if state != "RUNNABLE":
        msg = f"[stop_idle_db] Instance is already {state}. Nothing to do."
        print(msg)
        return msg, 200

    # Stop the instance by patching activationPolicy to NEVER
    patch_body = {"settings": {"activationPolicy": "NEVER"}}
    try:
        op = sqladmin.instances().patch(
            project=PROJECT_ID, instance=INSTANCE_ID, body=patch_body
        ).execute()
        msg = (f"[stop_idle_db] Sent STOP request for '{INSTANCE_ID}'. "
               f"Operation: {op.get('name')}")
        print(msg)
        return msg, 200
    except HttpError as e:
        msg = f"[stop_idle_db] ERROR stopping instance: {e}"
        print(msg)
        return msg, 500
