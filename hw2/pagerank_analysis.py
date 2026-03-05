#!/usr/bin/env python3
"""
CS 528 HW2 - PageRank Analysis

Reads HTML files from a Google Cloud Storage bucket (or local directory),
computes link statistics (average, median, max, min, quintiles) for
incoming and outgoing links, and calculates PageRank scores using the
iterative algorithm.

Usage:
    python pagerank_analysis.py --bucket BUCKET_NAME --prefix DIR_PREFIX
    python pagerank_analysis.py --local ./path_to_files
"""

import argparse
import re
import time
import os
import numpy as np
from collections import defaultdict


def parse_outgoing_links(html_content):
    """Extract outgoing link filenames from HTML content."""
    return re.findall(r'<a HREF="(\d+\.html)"', html_content)


def read_files_from_gcs(bucket_name, prefix, project):
    """Read all HTML files from a GCS bucket and extract outgoing links."""
    from google.cloud import storage

    client = storage.Client(project=project)
    bucket = client.bucket(bucket_name)

    # Ensure prefix ends with / if non-empty so we list directory contents
    if prefix and not prefix.endswith('/'):
        prefix += '/'

    blobs = [b for b in bucket.list_blobs(prefix=prefix) if b.name.endswith('.html')]
    total = len(blobs)
    print(f"  Found {total} HTML files in gs://{bucket_name}/{prefix}")

    outgoing = {}

    for i, blob in enumerate(blobs):
        content = blob.download_as_text()
        filename = blob.name.split('/')[-1]
        outgoing[filename] = parse_outgoing_links(content)
        if (i + 1) % 2000 == 0:
            print(f"  Processed {i+1}/{total} files...")

    return outgoing


def read_files_from_local(directory):
    """Read all HTML files from a local directory and extract outgoing links."""
    outgoing = {}
    files = sorted([f for f in os.listdir(directory) if f.endswith('.html')])
    total = len(files)
    print(f"  Found {total} HTML files in {directory}")

    for i, filename in enumerate(files):
        filepath = os.path.join(directory, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        outgoing[filename] = parse_outgoing_links(content)
        if (i + 1) % 5000 == 0:
            print(f"  Processed {i+1}/{total} files...")

    return outgoing


def compute_link_stats(outgoing):
    """Compute incoming and outgoing link counts for all pages."""
    all_pages = set(outgoing.keys())
    incoming_counts = defaultdict(int)
    outgoing_counts = {}

    for page, links in outgoing.items():
        outgoing_counts[page] = len(links)
        for link in links:
            if link in all_pages:
                incoming_counts[link] += 1

    # Pages with zero incoming links
    for page in all_pages:
        if page not in incoming_counts:
            incoming_counts[page] = 0

    return outgoing_counts, dict(incoming_counts)


def print_stats(values, label):
    """Print average, median, max, min, and quintiles."""
    arr = np.array(values, dtype=float)
    print(f"\n--- {label} ---")
    print(f"  Average:    {np.mean(arr):.2f}")
    print(f"  Median:     {np.median(arr):.2f}")
    print(f"  Max:        {int(np.max(arr))}")
    print(f"  Min:        {int(np.min(arr))}")
    quintiles = np.percentile(arr, [20, 40, 60, 80, 100])
    print(f"  Quintiles:")
    for q, v in zip([20, 40, 60, 80, 100], quintiles):
        print(f"    {q}th percentile: {v:.2f}")


def pagerank(outgoing, damping=0.85, threshold=0.005, verbose=True):
    """
    Iterative PageRank algorithm.

    PR(A) = (1 - d) / n + d * sum( PR(Ti) / C(Ti) )

    where T1..Tn are pages pointing to A, and C(Ti) is the number of
    outgoing links from Ti.

    Iterates until the sum of pagerank changes across all pages does
    not exceed `threshold` (0.5%) of the total PageRank sum:

        sum(|PR_new(i) - PR_old(i)|) / sum(PR_old(i))  <  threshold

    Returns:
        pr    - dict mapping page filename to its PageRank score
        iters - number of iterations until convergence
    """
    all_pages = set(outgoing.keys())
    pages = sorted(all_pages)
    n = len(pages)

    # Initialise every page with equal rank
    pr = {page: 1.0 / n for page in pages}

    # Build incoming map and outgoing counts
    incoming = defaultdict(list)
    out_count = {}

    for page in pages:
        links = [l for l in outgoing[page] if l in all_pages]
        out_count[page] = len(links)
        for link in links:
            incoming[link].append(page)

    iteration = 0

    while True:
        new_pr = {}
        for page in pages:
            rank_sum = 0.0
            for source in incoming[page]:
                if out_count[source] > 0:
                    rank_sum += pr[source] / out_count[source]
            new_pr[page] = (1 - damping) / n + damping * rank_sum

        # Convergence: sum of absolute PR changes / total PR
        total_diff = sum(abs(new_pr[p] - pr[p]) for p in pages)
        total_pr   = sum(pr.values())
        change = total_diff / total_pr if total_pr > 0 else float('inf')

        iteration += 1
        pr = new_pr

        if verbose:
            print(f"  Iteration {iteration}: sum(PR) = {sum(pr.values()):.8f}, "
                  f"change = {change:.6%}")

        if change < threshold:
            if verbose:
                print(f"  Converged after {iteration} iterations")
            break

    return pr, iteration


def main():
    parser = argparse.ArgumentParser(
        description="CS 528 HW2 - PageRank Analysis")
    parser.add_argument('--bucket', type=str,
                        help='Google Cloud Storage bucket name')
    parser.add_argument('--prefix', type=str, default='',
                        help='Directory prefix inside the bucket')
    parser.add_argument('--local', type=str,
                        help='Path to a local directory of HTML files')
    parser.add_argument('--project', type=str, default=None,
                        help='GCP project ID (required when using --bucket)')
    args = parser.parse_args()

    if not args.bucket and not args.local:
        parser.error("Specify either --bucket or --local")
    if args.bucket and not args.project:
        parser.error("--project is required when using --bucket")

    print("=" * 60)
    print("CS 528 HW2 - PageRank Analysis")
    print("=" * 60)

    total_start = time.time()

    # ---- Read files ----
    if args.local:
        print(f"\nReading from local directory: {args.local}")
        t0 = time.time()
        outgoing = read_files_from_local(args.local)
    else:
        print(f"\nReading from GCS: gs://{args.bucket}/{args.prefix}")
        t0 = time.time()
        outgoing = read_files_from_gcs(args.bucket, args.prefix, args.project)

    read_time = time.time() - t0
    print(f"  Loaded {len(outgoing)} files in {read_time:.2f}s")

    # ---- Link statistics ----
    print("\n" + "=" * 60)
    print("LINK STATISTICS")
    print("=" * 60)

    t0 = time.time()
    out_counts, in_counts = compute_link_stats(outgoing)

    out_values = [out_counts[p] for p in outgoing]
    in_values  = [in_counts[p]  for p in outgoing]

    print_stats(out_values, "Outgoing Links")
    print_stats(in_values,  "Incoming Links")
    stats_time = time.time() - t0
    print(f"\n  Stats computed in {stats_time:.2f}s")

    # ---- PageRank ----
    print("\n" + "=" * 60)
    print("PAGERANK")
    print("=" * 60)

    t0 = time.time()
    pr, iters = pagerank(outgoing)
    pr_time = time.time() - t0

    top5 = sorted(pr.items(), key=lambda x: x[1], reverse=True)[:5]
    print(f"\n  Top 5 Pages by PageRank:")
    for rank, (page, score) in enumerate(top5, 1):
        print(f"    {rank}. {page}:  PR = {score:.10f}")

    print(f"\n  PageRank computed in {pr_time:.2f}s ({iters} iterations)")

    # ---- Timing summary ----
    total_time = time.time() - total_start
    print("\n" + "=" * 60)
    print("TIMING SUMMARY")
    print("=" * 60)
    print(f"  File reading:    {read_time:.2f}s")
    print(f"  Link statistics: {stats_time:.2f}s")
    print(f"  PageRank:        {pr_time:.2f}s")
    print(f"  Total:           {total_time:.2f}s")


if __name__ == "__main__":
    main()
