#!/usr/bin/env python3
"""Summarize capacity JSONL without treating missing probes as zero."""

import argparse
import json
from pathlib import Path


def percentile(values, fraction):
    if not values:
        return None
    values = sorted(values)
    index = (len(values) - 1) * fraction
    lower = int(index)
    upper = min(lower + 1, len(values) - 1)
    return values[lower] + (values[upper] - values[lower]) * (index - lower)


def load_runs(inputs):
    paths = set()
    for path in inputs:
        path = Path(path)
        paths.update(path.rglob("metrics.jsonl") if path.is_dir() else [path])
    runs = []
    for path in sorted(paths):
        rows = []
        for line in path.read_text().splitlines():
            if "PERF_RESOURCE " in line:
                line = line.split("PERF_RESOURCE ", 1)[1]
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("schema_version") == 1:
                rows.append(row)
        for run_id in sorted({r["run_id"] for r in rows if r.get("run_id")}):
            selected = [r for r in rows if r.get("run_id") == run_id]
            samples = sorted(
                [r for r in selected if "process_cpu_ns" in r],
                key=lambda r: r["elapsed_s"],
            )
            if not samples:
                continue
            actions = [r for r in selected if r.get("event") == "action"]
            end = samples[-1]
            activity = next(
                (
                    r
                    for r in samples
                    if r.get("phase") in ("hold", "guard-stop", "safety_stop")
                ),
                end,
            )
            seconds = activity["elapsed_s"]
            durations = [r["action_duration_s"] * 1000 for r in actions]
            complete = any(
                r.get("event") == "end" and r.get("phase") in ("finished", "complete")
                for r in selected
            )
            result_path = path.parent / "result.json"
            if result_path.exists():
                complete = complete and json.loads(result_path.read_text()).get(
                    "completed", False
                )
            manifest_path = path.parent / "manifest.json"
            manifest = (
                json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
            )
            aggregate_path = path.parent / "instruments/aggregate.json"
            device = (
                json.loads(aggregate_path.read_text())
                if aggregate_path.exists()
                else None
            )
            if device and (
                not device.get("verified") or device.get("pid") != end["pid"]
            ):
                raise ValueError(f"Probe does not match workload: {path}")
            normal = [
                r
                for r in samples
                if r.get("phase") in ("grow", "typing")
                and r.get("interval_s", 0) >= 0.5
            ]
            summary = {
                "run_id": run_id,
                "source": str(path),
                "task": end["task"],
                "mode": end["mode"],
                "build": end.get("build_revision"),
                "bundle_sha256": manifest.get("bundle_sha256"),
                "completed": complete,
                "outcome": end["phase"],
                "profiled": device is not None
                or manifest.get("profiled", False)
                or (path.parent / "instruments").exists(),
                "initial_utf8_bytes": end["initial_payload_utf8_bytes"],
                "final_utf8_bytes": end["actual_payload_utf8_bytes"],
                "lines": end["lines"],
                "activity_seconds": seconds,
                "updates": end["delivery_count"],
                "achieved_hz": end["delivery_count"] / seconds if seconds else None,
                "mean_main_cpu_pct": 100 * activity["main_cpu_ns"] / 1e9 / seconds
                if seconds
                else None,
                "mean_process_cpu_pct": 100 * activity["process_cpu_ns"] / 1e9 / seconds
                if seconds
                else None,
                "main_cpu_ms_per_update": activity["main_cpu_ns"]
                / 1e6
                / end["delivery_count"]
                if end["delivery_count"]
                else None,
                "peak_process_cpu_pct": max(
                    (
                        100 * r["process_cpu_ns_delta"] / 1e9 / r["interval_s"]
                        for r in normal
                    ),
                    default=None,
                ),
                "action_p50_ms": percentile(durations, 0.5),
                "action_p95_ms": percentile(durations, 0.95),
                "action_max_ms": max(durations, default=None),
                "footprint_peak_bytes": max(
                    (
                        r["physical_footprint_bytes"]
                        for r in samples
                        if r.get("physical_footprint_bytes") is not None
                    ),
                    default=None,
                ),
                "disk_read_bytes": end.get("disk_read_bytes"),
                "disk_write_bytes": end.get("disk_write_bytes"),
                "devices": device,
            }
            runs.append({"summary": summary, "samples": samples, "actions": actions})
    return runs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--portable",
        action="store_true",
        help="Omit local paths and unrelated process details",
    )
    args = parser.parse_args()
    runs = load_runs(args.inputs)
    exported = []
    for run in runs:
        summary = run["summary"].copy()
        if args.portable:
            summary["source"] = Path(summary["source"]).name
            if summary["devices"]:
                device = summary["devices"]
                summary["devices"] = {
                    "capture": device["capture"],
                    "analysis": {
                        key: device["analysis"][key]
                        for key in (
                            "duration_s",
                            "gpu_app_union_s",
                            "gpu_active_fraction",
                            "ane_active_fraction",
                            "coreml_rows",
                            "scope",
                        )
                    },
                }
        summary["samples"] = [
            {
                key: r.get(key)
                for key in (
                    "elapsed_s",
                    "interval_s",
                    "phase",
                    "main_cpu_ns_delta",
                    "process_cpu_ns_delta",
                    "physical_footprint_bytes",
                    "disk_write_bytes",
                    "actual_payload_utf8_bytes",
                )
            }
            for r in run["samples"]
            if r.get("event") == "sample"
        ]
        summary["actions"] = [
            {
                key: r.get(key)
                for key in (
                    "elapsed_s",
                    "action_duration_s",
                    "actual_payload_utf8_bytes",
                )
            }
            for r in run["actions"]
        ]
        exported.append(summary)
    result = {
        "schema_version": 1,
        "runs": exported,
        "limits": [
            "A successful Swift test alone does not establish completed workload.",
            "CPU is percent of one core; action duration is not key-to-photon latency.",
            "Device activity is measured only inside verified capture bounds.",
            "Compare achieved delivery rate as well as requested cadence.",
        ],
    }
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    print(f"Wrote {len(runs)} runs to {args.output}")


if __name__ == "__main__":
    main()
