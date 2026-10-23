#!/usr/bin/env python3
"""Run opt-in release attribution experiments in an isolated macOS test checkout.

The private JSON configuration supplies tracks, profilesPath and modelRoot.
No model downloads or changes to the live app/library are requested.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


MODES = ("baseline", "per-turn", "multi-targeted")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--probe-count", type=int, default=3)
    parser.add_argument("--modes", nargs="+", choices=MODES, default=list(MODES))
    parser.add_argument("--source-revision", required=True)
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 20 or not 1 <= args.probe_count <= 12:
        parser.error("repetitions must be 1–20 and probe-count 1–12")
    checkout = args.checkout.resolve()
    repository = Path(__file__).resolve().parents[2]
    if not checkout.is_relative_to(repository / "tmp"):
        parser.error("checkout must be an independent source copy under the repository tmp/ directory")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    config = json.loads(args.config.read_text())
    for path in (output, Path(config["modelRoot"]).resolve()):
        if "tmp" not in path.parts and ".local" not in path.parts:
            parser.error("outputs and model root must use isolated tmp/ or .local/ storage")
    source = Path(__file__).with_name("AcousticAttributionHarnessTests.swift")
    target = checkout / "apps/client-macos-swift/Tests/GdayMeetingsTests" / source.name
    if target.exists():
        parser.error("the isolated checkout already contains this harness; preserve or remove it first")
    script = checkout / "apps/client-macos-swift/scripts/test-macos.sh"
    package_path = checkout / "apps/client-macos-swift/Package.swift"
    package_data = package_path.read_bytes()
    package_mode = package_path.stat().st_mode & 0o777
    package_text = package_data.decode()
    marker = 'name: "GdayMeetingsTests", dependencies: ["GdayMeetings", "AudioCaptureBridge"])'
    if package_text.count(marker) != 1:
        parser.error("the isolated test target manifest changed; update this experiment adapter")
    excluded_files = sorted(path.name for path in target.parent.iterdir() if path.name != source.name)
    restricted_package = package_text.replace(
        marker, marker[:-1] + f', exclude: {json.dumps(excluded_files)}, sources: ["{source.name}"])')
    hardware = {}
    for key in ("hw.model", "machdep.cpu.brand_string"):
        value = subprocess.run(["/usr/sbin/sysctl", "-n", key], capture_output=True, text=True)
        hardware[key] = value.stdout.strip() if value.returncode == 0 else "unavailable"
    expected_ranges = None
    metrics: dict = {
        "sourceRevision": args.source_revision,
        "hardware": hardware,
        "harnessSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "configurationSHA256": hashlib.sha256(args.config.read_bytes()).hexdigest(),
        "profileSHA256": hashlib.sha256(Path(config["profilesPath"]).read_bytes()).hexdigest(),
        "buildConfiguration": "release",
        "testTargetScope": "only experiment harness is compiled and loaded; production app module stays unchanged",
        "methodProcessIsolation": "one Swift test invocation per method; repetitions share loaded models",
        "timingScope": "outer process tree includes SwiftPM/test startup; report stage CPU/wall/RSS are sampled inside test process",
        "cacheScope": "first iteration has cold inference in this process; filesystem and Core ML caches are uncontrolled",
        "runs": [],
    }
    shutil.copyfile(source, target)
    try:
        package_path.write_text(restricted_package)
        with (output / "build.log").open("w") as log:
            subprocess.run(
                ["bash", str(script), "-c", "release", "--filter", "AcousticAttributionHarnessTests"],
                cwd=checkout,
                env={**os.environ, "GDAY_ATTRIBUTION_EXPERIMENT": "0"},
                stdout=log, stderr=subprocess.STDOUT, check=True,
            )
        for mode in args.modes:
            runtime = {**config, "mode": mode, "repetitions": args.repetitions,
                       "probeCount": args.probe_count,
                       "consistencyCosineFloor": config.get("consistencyCosineFloor", 0.55),
                       "identityScoreFloor": config.get("identityScoreFloor", 0.55),
                       "minimumMargin": config.get("minimumMargin", 0.08)}
            config_path = output / f"{mode}-config.json"
            report_path = output / f"{mode}.json"
            log_path = output / f"{mode}.log"
            config_path.write_text(json.dumps(runtime, indent=2) + "\n")
            config_path.chmod(0o600)
            environment = {**os.environ,
                           "GDAY_ATTRIBUTION_EXPERIMENT": "1",
                           "GDAY_ATTRIBUTION_CONFIG": str(config_path),
                           "GDAY_ATTRIBUTION_OUTPUT": str(report_path),
                           "GDAY_ATTRIBUTION_SOURCE_REVISION": args.source_revision}
            report_path.unlink(missing_ok=True)
            before_load = os.getloadavg()
            started = time.perf_counter()
            with log_path.open("w") as log:
                completed = subprocess.run(
                    ["/usr/bin/time", "-l", "bash", str(script), "--skip-build", "-c", "release",
                     "--filter", "AcousticAttributionHarnessTests"],
                    cwd=checkout, env=environment, stdout=log, stderr=subprocess.STDOUT,
                )
            record = {"mode": mode, "invocationWallSeconds": time.perf_counter() - started,
                      "loadAverageBefore": before_load, "loadAverageAfter": os.getloadavg(),
                      "exitCode": completed.returncode}
            text = log_path.read_text()
            rss = re.search(r"(\d+)\s+maximum resident set size", text)
            usage = re.search(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", text)
            if rss:
                record["processTreeMaximumRSSBytes"] = int(rss[1])
            if usage:
                record["processTreeTime"] = dict(zip(("real", "user", "sys"), map(float, usage.groups())))
            metrics["runs"].append(record)
            (output / "runner-metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
            completed.check_returncode()
            if not report_path.is_file():
                raise RuntimeError("the opt-in test did not produce its report")
            report = json.loads(report_path.read_text())
            if (report.get("mode") != mode or len(report.get("runs", [])) != args.repetitions
                    or report.get("sourceRevision") != args.source_revision):
                raise RuntimeError("report does not match the current invocation")
            for run in report["runs"]:
                ranges = sorted((row["track"], row["label"], row["start"], row["end"])
                                for row in run["assignments"])
                if expected_ranges is None:
                    expected_ranges = ranges
                elif ranges != expected_ranges:
                    raise RuntimeError("acoustic labels or boundaries changed across methods/repetitions")
            print(f"Completed {mode}: {args.repetitions} iterations", flush=True)
    finally:
        package_path.write_bytes(package_data)
        package_path.chmod(package_mode)
        target.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
