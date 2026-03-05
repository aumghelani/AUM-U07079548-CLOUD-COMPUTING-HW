#!/usr/bin/env python3
"""
Upload generated HTML files to a Google Cloud Storage bucket.

Usage:
    python upload_to_gcs.py --bucket BUCKET_NAME --source ./files_dir --prefix hw2

Alternatively you can use gsutil directly (often faster):
    gsutil -m cp ./files_dir/*.html gs://BUCKET_NAME/hw2/
"""

import argparse
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from google.cloud import storage


def upload_files(bucket_name, source_dir, prefix, project):
    client = storage.Client(project=project)
    bucket = client.bucket(bucket_name)

    files = sorted([f for f in os.listdir(source_dir) if f.endswith('.html')])
    total = len(files)
    print(f"Uploading {total} files to gs://{bucket_name}/{prefix}/")

    completed = [0]

    def upload_one(filename):
        blob_name = f"{prefix}/{filename}" if prefix else filename
        blob = bucket.blob(blob_name)
        blob.upload_from_filename(os.path.join(source_dir, filename))
        return filename

    with ThreadPoolExecutor(max_workers=32) as executor:
        futures = {executor.submit(upload_one, f): f for f in files}
        for future in as_completed(futures):
            future.result()
            completed[0] += 1
            if completed[0] % 2000 == 0:
                print(f"  Uploaded {completed[0]}/{total} files...")

    print(f"Done! Uploaded {total} files to gs://{bucket_name}/{prefix}/")


def main():
    parser = argparse.ArgumentParser(
        description="Upload HTML files to Google Cloud Storage")
    parser.add_argument('--bucket', required=True,
                        help='GCS bucket name')
    parser.add_argument('--source', required=True,
                        help='Local directory containing HTML files')
    parser.add_argument('--prefix', default='',
                        help='Destination directory prefix inside the bucket')
    parser.add_argument('--project', required=True,
                        help='GCP project ID')
    args = parser.parse_args()

    upload_files(args.bucket, args.source, args.prefix, args.project)


if __name__ == "__main__":
    main()
