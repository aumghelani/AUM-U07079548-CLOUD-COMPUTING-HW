#!/usr/bin/env python3
"""
link_analysis.py - Apache Beam pipeline to find:
  1. Top 5 files with the most INCOMING links
  2. Top 5 files with the most OUTGOING links

Reads HTML files from GCS bucket (gs://aum-hw2-u07079548/hw2/).
Links are in format: <a HREF="123.html">

Usage (local):
    python link_analysis.py

Usage (Cloud Dataflow):
    python link_analysis.py \
        --runner DataflowRunner \
        --project u0709548-aum-hw1 \
        --region us-central1 \
        --temp_location gs://aum-hw2-u07079548/hw7-temp/ \
        --staging_location gs://aum-hw2-u07079548/hw7-staging/
"""

import argparse
import logging
import re
import sys
import threading
import time

import apache_beam as beam
from apache_beam.options.pipeline_options import PipelineOptions

# Suppress noisy warnings
logging.getLogger("urllib3.connectionpool").setLevel(logging.ERROR)
logging.getLogger("google.auth").setLevel(logging.ERROR)
logging.getLogger("apache_beam").setLevel(logging.WARNING)

BUCKET = "aum-hw2-u07079548"
FILE_PREFIX = "hw2"
PROJECT_ID = "u0709548-aum-hw1"
NUM_FILES = 20000
BATCH_SIZE = 200
LINK_PATTERN = re.compile(r'<a\s+HREF="(\d+\.html)"', re.IGNORECASE)


class ReadBatchAndExtractLinks(beam.DoFn):
    """Read a batch of files using per-thread GCS clients, extract links."""

    def process(self, batch):
        from concurrent.futures import ThreadPoolExecutor
        local = threading.local()

        def get_bucket():
            if not hasattr(local, "bucket"):
                from google.cloud import storage
                local.client = storage.Client(project=PROJECT_ID)
                local.bucket = local.client.bucket(BUCKET)
            return local.bucket

        def read_one(idx):
            b = get_bucket()
            blob = b.blob(f"{FILE_PREFIX}/{idx}.html")
            try:
                return (f"{idx}.html", blob.download_as_text())
            except Exception:
                return (f"{idx}.html", "")

        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(read_one, batch))

        print(f"  Read {batch[0]}-{batch[-1]} ({len(batch)} files)", flush=True)

        for filename, content in results:
            if not content:
                continue
            targets = LINK_PATTERN.findall(content)
            yield beam.pvalue.TaggedOutput("outgoing", (filename, len(targets)))
            for target in targets:
                yield beam.pvalue.TaggedOutput("incoming", (target, 1))


def format_result(element):
    return f"  {element[0]}: {element[1]}"


def get_runner(pipeline_args):
    """Use legacy BundleBasedDirectRunner for local, DataflowRunner for cloud."""
    for arg in pipeline_args:
        if "DataflowRunner" in arg:
            return None
    from apache_beam.runners.direct.direct_runner import BundleBasedDirectRunner
    return BundleBasedDirectRunner()


def run(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--num_files", type=int, default=NUM_FILES)
    parser.add_argument("--batch_size", type=int, default=BATCH_SIZE)
    known_args, pipeline_args = parser.parse_known_args(argv)

    options = PipelineOptions(pipeline_args)
    runner = get_runner(pipeline_args)

    batches = []
    for i in range(0, known_args.num_files, known_args.batch_size):
        batches.append(list(range(i, min(i + known_args.batch_size, known_args.num_files))))

    print(f"Link Analysis: {known_args.num_files} files in {len(batches)} batches")

    start_time = time.time()

    p = beam.Pipeline(runner=runner, options=options)

    links = (
        p
        | "CreateBatches" >> beam.Create(batches)
        | "ReadAndExtract" >> beam.ParDo(
            ReadBatchAndExtractLinks()
        ).with_outputs("outgoing", "incoming")
    )

    # Top 5 OUTGOING links
    top_outgoing = (
        links.outgoing
        | "TopOutgoing" >> beam.combiners.Top.Of(5, key=lambda x: x[1])
        | "FlattenOutgoing" >> beam.FlatMap(lambda x: x)
        | "FormatOutgoing" >> beam.Map(format_result)
    )
    top_outgoing | "PrintOutgoing" >> beam.Map(
        lambda x: print(f"[OUTGOING] {x}")
    )

    # Top 5 INCOMING links
    top_incoming = (
        links.incoming
        | "SumIncoming" >> beam.CombinePerKey(sum)
        | "TopIncoming" >> beam.combiners.Top.Of(5, key=lambda x: x[1])
        | "FlattenIncoming" >> beam.FlatMap(lambda x: x)
        | "FormatIncoming" >> beam.Map(format_result)
    )
    top_incoming | "PrintIncoming" >> beam.Map(
        lambda x: print(f"[INCOMING] {x}")
    )

    result = p.run()
    result.wait_until_finish()

    elapsed = time.time() - start_time

    print()
    print("=" * 60)
    print("LINK ANALYSIS COMPLETE")
    print(f"  Total runtime: {elapsed:.2f} seconds")
    print("=" * 60)


if __name__ == "__main__":
    run()
