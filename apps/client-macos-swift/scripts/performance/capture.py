#!/usr/bin/env python3
"""Bounded Instruments capture; aggregate devices before removing intermediates."""

import argparse
import fcntl
import json
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from trace_metrics import (
    TABLES,
    atomic_json,
    cpu_metrics,
    parse_accelerators,
    sha256,
    toc_info,
    tree_bytes,
)


def capture(pid, output, budget_root, gate=None, keep_trace=False, keep_cpu_xml=False):
    budget_root = Path(budget_root).resolve(strict=True)
    lock_path = budget_root / ".capture.lock"
    if lock_path.is_symlink():
        raise ValueError("Capture lock cannot be a symlink")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _capture(pid, output, budget_root, gate, keep_trace, keep_cpu_xml)


def _capture(pid, output, budget_root, gate=None, keep_trace=False, keep_cpu_xml=False):
    output = Path(output).absolute()
    output.mkdir(parents=True, exist_ok=False)
    output = output.resolve()
    budget_root = Path(budget_root).resolve(strict=True)
    if not output.is_relative_to(budget_root):
        raise ValueError("Capture output must be inside the budget directory")
    cap, floor, scratch = 8 * 2**30, 20 * 2**30, 3 * 2**30
    if (
        tree_bytes(budget_root) + scratch > cap
        or shutil.disk_usage(output).free - scratch < floor
    ):
        raise RuntimeError(
            "Insufficient capture budget: allow 3 GiB scratch within 8 GiB, with 20 GiB free"
        )
    trace = output / "sample.trace"
    exports = {key: output / (key + ".xml") for key in (*TABLES, "toc")}
    commands = []
    started = datetime.now(timezone.utc).isoformat()
    deadline = time.monotonic() + 360

    def run(command, name, release_gate=False):
        commands.append(command)
        log = output / (name + ".log")
        with log.open("xb") as stream:
            process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
            limit = min(deadline, time.monotonic() + 160)
            try:
                while process.poll() is None:
                    if (
                        release_gate
                        and gate
                        and "Ctrl-C to stop the recording"
                        in log.read_text(errors="replace")
                    ):
                        with Path(gate).open("x") as trigger:
                            json.dump(
                                {
                                    "utc": datetime.now(timezone.utc).isoformat(),
                                    "pid": pid,
                                },
                                trigger,
                            )
                        release_gate = False
                    if (
                        time.monotonic() > limit
                        or tree_bytes(budget_root) > cap
                        or shutil.disk_usage(output).free < floor
                    ):
                        process.send_signal(signal.SIGINT)
                        try:
                            process.wait(timeout=20)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                        raise RuntimeError(
                            "Capture command reached its time or disk guard"
                        )
                    time.sleep(1)
                if process.returncode:
                    raise RuntimeError(
                        f"{name} exited {process.returncode}; inspect {log.name}"
                    )
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()

    try:
        run(
            [
                "xcrun",
                "xctrace",
                "record",
                "--template",
                "Time Profiler",
                "--instrument",
                "GPU",
                "--instrument",
                "Neural Engine",
                "--instrument",
                "Core ML",
                "--attach",
                str(pid),
                "--time-limit",
                "20s",
                "--output",
                str(trace),
            ],
            "record",
            True,
        )
        for key, path in exports.items():
            query = (
                ["--toc"]
                if key == "toc"
                else [
                    "--xpath",
                    f'/trace-toc/run[@number="1"]/data/table[@schema="{TABLES[key]}"]',
                ]
            )
            run(
                [
                    "xcrun",
                    "xctrace",
                    "export",
                    "--input",
                    str(trace),
                    "--output",
                    str(path),
                    *query,
                ],
                "export-" + key,
            )
        info = toc_info(exports["toc"], pid)
        result = {
            "schema_version": 1,
            "verified": True,
            "pid": pid,
            "started_utc": started,
            "capture": info,
            "requested_capture_completed": info["duration_s"] >= 20
            and info["end_reason"] == "Time limit reached",
            "cpu": cpu_metrics(exports["cpu"], info["duration_s"]),
            "analysis": parse_accelerators(exports, info["duration_s"], pid),
            "exports": {
                key: {
                    "file": path.name,
                    "bytes": path.stat().st_size,
                    "sha256": sha256(path),
                }
                for key, path in exports.items()
            },
            "commands": commands,
        }
        atomic_json(output / "aggregate.json", result)
        # JSON changes tuples to lists; compare normalized representations.
        if json.loads(json.dumps(result)) != json.loads(
            (output / "aggregate.json").read_text()
        ):
            raise RuntimeError("Aggregate did not persist correctly")
        if not keep_trace:
            shutil.rmtree(trace)
            for key in ("gpu", "ane", "coreml", *(() if keep_cpu_xml else ("cpu",))):
                exports[key].unlink()
        return result
    except Exception as error:
        atomic_json(
            output / "failure.json",
            {
                "verified": False,
                "pid": pid,
                "started_utc": started,
                "error": str(error),
                "commands": commands,
                "retained_bytes": tree_bytes(output),
            },
        )
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument(
        "--output", type=Path, required=True, help="New capture directory"
    )
    parser.add_argument(
        "--budget-root",
        type=Path,
        required=True,
        help="Shared directory for all captures",
    )
    parser.add_argument(
        "--gate", type=Path, help="Absent start-gate file; opened when recording starts"
    )
    parser.add_argument("--keep-trace", action="store_true")
    parser.add_argument(
        "--keep-cpu-xml",
        action="store_true",
        help="Retain detailed stacks for diagnosis",
    )
    args = parser.parse_args()
    if args.pid <= 1 or (args.gate and args.gate.exists()):
        parser.error("Use a valid PID and an absent gate")
    result = capture(
        args.pid,
        args.output,
        args.budget_root,
        args.gate,
        args.keep_trace,
        args.keep_cpu_xml,
    )
    print(
        json.dumps(
            {
                "verified": result["verified"],
                "capture": result["capture"],
                "analysis": result["analysis"],
            }
        )
    )


if __name__ == "__main__":
    main()
