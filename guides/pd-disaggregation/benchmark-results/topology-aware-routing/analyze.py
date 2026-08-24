#!/usr/bin/env python3
"""Regenerate aggregate statistics for the topology-aware routing benchmark."""

import csv
import math
import statistics
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parent
METRICS = ("qps", "ttft_mean", "ttft_p99", "e2e_mean", "e2e_p99")


def load_paired_rows():
    rows = []
    runs = ROOT / "artifacts" / "paired-64k"
    for run_dir in sorted(runs.glob("run-*"), key=lambda path: int(path.name.split("-")[1])):
        reports = list(run_dir.glob("**/benchmark_report_v0.2,*"))
        if len(reports) != 1:
            raise RuntimeError(f"expected one v0.2 report under {run_dir}, found {len(reports)}")
        aggregate = yaml.safe_load(reports[0].read_text())["results"]["request_performance"]["aggregate"]
        latency = aggregate["latency"]
        requests = aggregate["requests"]
        throughput = aggregate["throughput"]
        _, run, policy = run_dir.name.split("-")
        rows.append(
            {
                "run": int(run),
                "policy": policy,
                "qps": throughput["request_rate"]["mean"],
                "ttft_mean": latency["time_to_first_token"]["mean"],
                "ttft_p99": latency["time_to_first_token"]["p99"],
                "e2e_mean": latency["request_latency"]["mean"],
                "e2e_p99": latency["request_latency"]["p99"],
                "total_requests": requests["total"],
                "failures": requests["failures"],
                "report": str(reports[0].relative_to(ROOT)),
            }
        )
    return rows


def write_rows(rows):
    destination = ROOT / "artifacts" / "paired-64k" / "summary.csv"
    with destination.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0], lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    return destination


def main():
    rows = load_paired_rows()
    if len(rows) != 6:
        raise RuntimeError(f"expected six paired runs, found {len(rows)}")
    destination = write_rows(rows)
    print(f"wrote {destination.relative_to(ROOT)}")

    print("\npolicy means")
    for policy in ("local", "remote"):
        policy_rows = [row for row in rows if row["policy"] == policy]
        values = {metric: statistics.mean(row[metric] for row in policy_rows) for metric in METRICS}
        print(policy, " ".join(f"{metric}={value:.6f}" for metric, value in values.items()))

    by_run = {row["run"]: row for row in rows}
    # Each tuple is (local run, remote run); the middle block reverses order.
    pairs = ((1, 2), (4, 3), (5, 6))
    differences = [
        {metric: by_run[remote][metric] - by_run[local][metric] for metric in METRICS}
        for local, remote in pairs
    ]
    print("\npaired remote-minus-local means and 95% confidence intervals")
    t_95_df_2 = 4.303
    for metric in METRICS:
        samples = [difference[metric] for difference in differences]
        mean = statistics.mean(samples)
        half_width = t_95_df_2 * statistics.stdev(samples) / math.sqrt(len(samples))
        print(f"{metric} mean={mean:.6f} ci=[{mean - half_width:.6f}, {mean + half_width:.6f}]")


if __name__ == "__main__":
    main()
