#!/usr/bin/env python3
"""
bigram_analysis.py - Apache Beam pipeline to find the top 5 most frequent
word bigrams in HTML files from GCS bucket (gs://aum-hw2-u07079548/hw2/).

A bigram is a pair of consecutive words. HTML tags are stripped first,
then text is lowercased and split into words.

Usage (local):
    python bigram_analysis.py

Usage (Cloud Dataflow):
    python bigram_analysis.py \
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
from collections import Counter

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

# Regex to strip HTML tags
HTML_TAG_PATTERN = re.compile(r"<[^>]+>")
# Regex to extract words (letters only)
WORD_PATTERN = re.compile(r"[a-z]+")


class ReadBatchAndCountBigrams(beam.DoFn):
    """Read a batch of files, extract bigrams, and emit pre-aggregated counts.

    Instead of emitting millions of (bigram, 1) tuples, we count bigrams
    per-batch and emit (bigram, count) to reduce memory usage.
    """

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
                return blob.download_as_text()
            except Exception:
                return ""

        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(read_one, batch))

        print(f"  Read {batch[0]}-{batch[-1]} ({len(batch)} files)", flush=True)

        # Count bigrams across the entire batch before emitting
        batch_counts = Counter()
        for content in results:
            if not content:
                continue
            text = HTML_TAG_PATTERN.sub(" ", content)
            words = WORD_PATTERN.findall(text.lower())
            for i in range(len(words) - 1):
                batch_counts[f"{words[i]} {words[i+1]}"] += 1

        # Emit pre-aggregated (bigram, count) pairs
        for bigram, count in batch_counts.items():
            yield (bigram, count)


def format_result(element):
    return f"  '{element[0]}': {element[1]}"


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

    print(f"Bigram Analysis: {known_args.num_files} files in {len(batches)} batches")

    start_time = time.time()

    p = beam.Pipeline(runner=runner, options=options)

    bigram_counts = (
        p
        | "CreateBatches" >> beam.Create(batches)
        | "ReadAndCount" >> beam.ParDo(ReadBatchAndCountBigrams())
    )

    top_bigrams = (
        bigram_counts
        | "SumBigrams" >> beam.CombinePerKey(sum)
        | "Top5Bigrams" >> beam.combiners.Top.Of(5, key=lambda x: x[1])
        | "Flatten" >> beam.FlatMap(lambda x: x)
        | "Format" >> beam.Map(format_result)
    )

    top_bigrams | "PrintBigrams" >> beam.Map(
        lambda x: print(f"[BIGRAM] {x}")
    )

    result = p.run()
    result.wait_until_finish()

    elapsed = time.time() - start_time

    print()
    print("=" * 60)
    print("BIGRAM ANALYSIS COMPLETE")
    print(f"  Total runtime: {elapsed:.2f} seconds")
    print("=" * 60)


if __name__ == "__main__":
    run()
