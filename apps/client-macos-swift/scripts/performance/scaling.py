#!/usr/bin/env python3
"""Run equal-work, repeated payload comparisons and enforce a bounded growth contract."""

import argparse
import json
import math
import os
import platform
import statistics
import subprocess
import sys
from pathlib import Path

from analyze import load_runs, percentile
from trace_metrics import atomic_json

CASES = [
    "notes:append",
    "notes:beginning",
    "notes:middle",
    "notes:style",
    "notes:image",
    "summary:visible",
    "summary:hidden",
]


def growth(small, large, limit, zero_is_valid=False):
    """Repeat-spread guard, not a confidence interval or a hardware-independent timing proof."""
    if len(small) < 3 or len(large) < 3:
        return {
            "status": "inconclusive",
            "reason": "At least three completed repeats are required",
        }
    if any(x is None or not math.isfinite(x) or x < 0 for x in small + large):
        return {"status": "inconclusive", "reason": "Missing or invalid counter"}
    if zero_is_valid and max(small + large) == 0:
        return {
            "status": "pass",
            "median_ratio": 1.0,
            "reason": "Both observed counters are zero",
        }
    if min(small) <= 0:
        return {
            "status": "inconclusive",
            "reason": "Baseline is below counter resolution",
        }
    lower = percentile(large, 0.25) / percentile(small, 0.75)
    upper = percentile(large, 0.75) / percentile(small, 0.25)
    return {
        "status": "fail"
        if lower > limit
        else "pass"
        if upper <= limit
        else "inconclusive",
        "median_ratio": statistics.median(large) / statistics.median(small),
        "repeat_spread_ratio": [lower, upper],
        "limit": limit,
    }


def metrics(path, operations):
    runs = load_runs([path])
    if len(runs) != 1:
        raise ValueError("Expected exactly one measured workload")
    run = runs[0]
    value = run["summary"]
    if (
        not value["completed"]
        or value["profiled"]
        or value["updates"] != operations
        or len(run["actions"]) != operations
    ):
        raise ValueError("Incomplete, profiled, or unequal-work run")
    # Fixed identical input batches make per-operation costs meaningful even at 100% CPU.
    initial = run["samples"][0]
    return {
        # Include the five-second settle/save window so deferring work cannot make the gate pass.
        "main_cpu_ms_per_operation": run["samples"][-1]["main_cpu_ns"]
        / 1e6
        / operations,
        "process_cpu_ms_per_operation": run["samples"][-1]["process_cpu_ns"]
        / 1e6
        / operations,
        "p95_operation_ms": value["action_p95_ms"],
        "incremental_peak_footprint_bytes": max(
            0, value["footprint_peak_bytes"] - initial["physical_footprint_bytes"]
        ),
        "total_process_writes_per_operation": value["disk_write_bytes"] / operations
        if value["disk_write_bytes"] is not None
        else None,
        "initial_footprint_bytes": initial["physical_footprint_bytes"],
        "final_payload_bytes": value["final_utf8_bytes"],
        "bundle_sha256": value["bundle_sha256"],
        "task": value["task"],
        "mode": value["mode"],
        "initial_payload_bytes": value["initial_utf8_bytes"],
    }


def evaluate(root):
    plan = json.loads((root / "plan.json").read_text())
    groups = {}
    invalid = []
    hashes = set()
    for entry in plan["runs"]:
        try:
            value = metrics(
                root / entry["directory"] / "metrics.jsonl", plan["operations"]
            )
            task, mode = entry["case"].split(":")
            expected_mode = "component-" + mode if task == "notes" else mode
            if (
                value["task"] != task
                or value["mode"] != expected_mode
                or abs(value["initial_payload_bytes"] - entry["bytes"]) > 1024
            ):
                raise ValueError(
                    "Measured case or payload does not match the planned fixture"
                )
            hashes.add(value["bundle_sha256"])
            groups.setdefault((entry["case"], entry["bytes"]), []).append(value)
        except (ValueError, OSError, KeyError, TypeError) as error:
            result_path = root / entry["directory"] / "result.json"
            outcome = (
                json.loads(result_path.read_text()) if result_path.exists() else {}
            )
            guarded = outcome.get("outcome") in (
                "guard-stop",
                "safety_stop",
            ) or outcome.get("timed_out", False)
            invalid.append(
                {
                    "run": entry["directory"],
                    "reason": str(error),
                    "performance_guard": guarded,
                }
            )
    provenance_valid = len(hashes) == 1 and None not in hashes
    if not provenance_valid:
        invalid.append({"reason": "Runs must use one known release binary hash"})
    comparisons = []
    for case in plan["cases"]:
        baseline = groups.get((case, plan["sizes"][0]), []) if provenance_valid else []
        for size in plan["sizes"][1:]:
            larger = groups.get((case, size), []) if provenance_valid else []
            for metric in [
                "main_cpu_ms_per_operation",
                "process_cpu_ms_per_operation",
                "p95_operation_ms",
                "total_process_writes_per_operation",
            ]:
                result = growth(
                    [x[metric] for x in baseline],
                    [x[metric] for x in larger],
                    plan["maximum_ratio"],
                    zero_is_valid=metric == "total_process_writes_per_operation",
                )
                comparisons.append(
                    {
                        "case": case,
                        "baseline_bytes": plan["sizes"][0],
                        "larger_bytes": size,
                        "metric": metric,
                        **result,
                    }
                )
    # Incremental footprint is reported, not treated as allocation cost: allocator retention and
    # missing allocation counters make a peak-minus-start ratio unreliable as a universal gate.
    status = (
        "fail"
        if any(x["status"] == "fail" for x in comparisons)
        or any(x.get("performance_guard") for x in invalid)
        else "inconclusive"
        if invalid or any(x["status"] == "inconclusive" for x in comparisons)
        else "pass"
    )
    report = {
        "schema_version": 1,
        "machine": plan.get("machine"),
        "protocol": {
            key: plan[key]
            for key in ("sizes", "repeats", "operations", "maximum_ratio")
        },
        "status": status,
        "comparisons": comparisons,
        "invalid_runs": invalid,
        "observations": [
            {"case": case, "bytes": size, "repeats": rows}
            for (case, size), rows in groups.items()
        ],
        "coverage": {
            "cpu_latency_disk": "Equal-work native component tests; CPU and disk include settling and Notes flush",
            "memory": "Incremental peak footprint reported; no allocation/retention proof",
            "gpu_ane_coreml": "Not measured in unprofiled scaling runs; use separate hardware captures",
            "live_models": "Not exercised by document fixtures; use the model-enabled recording lane",
        },
    }
    # Evaluation can be repeated after completing interrupted runs.
    output = root / "scaling-report.json"
    output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(
        json.dumps(
            {"status": status, "report": str(output), "invalid_runs": len(invalid)}
        )
    )
    return 0 if status == "pass" else 1 if status == "fail" else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--evaluate-only", action="store_true")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--sizes", nargs="+", type=int, default=[10240, 102400, 512000])
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--operations", type=int, default=12)
    parser.add_argument("--maximum-ratio", type=float, default=2.0)
    parser.add_argument("--revision", default="unspecified")
    args = parser.parse_args()
    if args.evaluate_only:
        return evaluate(args.output)
    if not args.bundle or args.repeats < 3 or not 1 <= args.operations <= 250:
        parser.error(
            "Provide a release bundle, at least three repeats, and 1–250 operations"
        )
    if (
        len(args.sizes) < 3
        or args.sizes != sorted(set(args.sizes))
        or args.sizes[0] < 1024
        or args.sizes[-1] > 512000
        or args.sizes[-1] / args.sizes[0] < 10
    ):
        parser.error(
            "Use at least three increasing sizes spanning at least 10×, within 1–500 KiB"
        )
    if not math.isfinite(args.maximum_ratio) or args.maximum_ratio < 1:
        parser.error("Maximum ratio must be finite and at least one")
    if len(args.cases) != len(set(args.cases)):
        parser.error("Each case must be unique")
    args.output.mkdir(parents=True, exist_ok=False)
    entries = []
    for repeat in range(args.repeats):
        sizes = (
            args.sizes[repeat % len(args.sizes) :]
            + args.sizes[: repeat % len(args.sizes)]
        )
        for case in args.cases:
            for size in sizes:
                entries.append(
                    {
                        "case": case,
                        "bytes": size,
                        "repeat": repeat,
                        "directory": f"{case.replace(':', '-')}-{size}-r{repeat}",
                    }
                )
    atomic_json(
        args.output / "plan.json",
        {
            "machine": {
                "platform": platform.platform(),
                "architecture": platform.machine(),
                "logical_cpus": os.cpu_count(),
            },
            "cases": args.cases,
            "sizes": args.sizes,
            "operations": args.operations,
            "repeats": args.repeats,
            "maximum_ratio": args.maximum_ratio,
            "runs": entries,
        },
    )
    for entry in entries:
        task, mode = entry["case"].split(":")
        command = [
            sys.executable,
            str(Path(__file__).with_name("run.py")),
            task,
            "--bundle",
            str(args.bundle),
            "--output",
            str(args.output / entry["directory"]),
            "--bytes",
            str(entry["bytes"]),
            "--mode",
            mode,
            "--operations",
            str(args.operations),
            "--revision",
            args.revision,
        ]
        # A guard is a measured failure, not permission to discard the case or shrink its payload.
        subprocess.run(command, check=False)
    return evaluate(args.output)


if __name__ == "__main__":
    sys.exit(main())
