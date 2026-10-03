#!/usr/bin/env python3
"""Run one synthetic Notes or Summary workload in an isolated native test host."""

import argparse
import json
import logging
import os
import plistlib
import shutil
import subprocess
import sys
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from capture import capture
from trace_metrics import atomic_json, sha256

logger = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task", choices=["notes", "summary"])
    parser.add_argument(
        "--bundle",
        type=Path,
        required=True,
        help="Built release GdayMeetingsTests.xctest",
    )
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="New run directory; never overwritten",
    )
    parser.add_argument("--bytes", type=int, default=10240)
    parser.add_argument(
        "--mode",
        choices=[
            "append",
            "beginning",
            "middle",
            "style",
            "image",
            "visible",
            "hidden",
        ],
    )
    parser.add_argument(
        "--workspace", choices=["component", "library"], default="component"
    )
    parser.add_argument(
        "--revision",
        default="unspecified",
        help="Commit plus description of uncommitted changes",
    )
    parser.add_argument(
        "--operations",
        type=int,
        help="Fixed batch size, 1 through 250; required for scaling comparisons",
    )
    parser.add_argument("--profile", action="store_true")
    parser.add_argument(
        "--budget-root",
        type=Path,
        help="Shared capture directory; required with --profile",
    )
    parser.add_argument(
        "--manual-gate",
        action="store_true",
        help="Wait for external gate file after UI setup",
    )
    args = parser.parse_args()
    if args.operations is not None and not 1 <= args.operations <= 250:
        parser.error("--operations must be between 1 and 250")
    mode = args.mode or ("append" if args.task == "notes" else "visible")
    if not 1024 <= args.bytes <= 512000:
        parser.error("Use 1024 through 512000 bytes")
    if mode not in (
        ["append", "beginning", "middle", "style", "image"]
        if args.task == "notes"
        else ["visible", "hidden"]
    ):
        parser.error("Mode does not match task")
    if args.profile and not args.budget_root:
        parser.error("--profile requires --budget-root")
    if args.workspace == "library" and args.task == "notes" and not args.manual_gate:
        parser.error(
            "Full-library Notes requires --manual-gate so Notes can be selected before measurement"
        )
    if args.manual_gate and args.profile:
        parser.error(
            "For manual UI setup, run capture.py separately after selecting Notes"
        )
    executable = args.bundle.resolve(strict=True) / "Contents/MacOS/GdayMeetingsTests"
    if not executable.is_file():
        parser.error("Test executable is missing")
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    output = output.resolve()
    swift = Path(
        subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    )
    toolchain = swift.parent.parent
    helper = toolchain / "libexec/swift/pm/swiftpm-testing-helper"
    if not helper.is_file():
        raise RuntimeError(f"Apple Swift test helper is unavailable: {helper}")
    app = output / "Gday Capacity Runner.app"
    binary = app / "Contents/MacOS/GdayCapacityRunner"
    binary.parent.mkdir(parents=True)
    shutil.copy2(helper, binary)
    bundle_id = "com.gdaymeetings.capacity." + uuid.uuid4().hex
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": bundle_id,
                "CFBundleName": "Gday Capacity Runner",
                "CFBundleDisplayName": "Gday Capacity Runner",
                "CFBundleExecutable": binary.name,
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
                "NSPrincipalClass": "NSApplication",
                "NSHighResolutionCapable": True,
            }
        )
    )
    subprocess.run(
        ["codesign", "--force", "--sign", "-", str(app)],
        check=True,
        capture_output=True,
    )
    # Do not copy credentials or terminal escape codes into the Instruments environment table.
    env = {
        key: os.environ[key]
        for key in ("HOME", "USER", "LOGNAME", "TMPDIR", "PATH")
        if key in os.environ
    }
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    frameworks = [
        developer / "Library/Developer/Frameworks",
        developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks",
    ]
    libraries = [
        developer / "Library/Developer/usr/lib",
        developer / "Platforms/MacOSX.platform/Developer/usr/lib",
    ]
    env.update(
        DYLD_FRAMEWORK_PATH=":".join(str(p) for p in frameworks if p.is_dir()),
        DYLD_LIBRARY_PATH=":".join(str(p) for p in libraries if p.is_dir()),
        GDAY_PERFORMANCE_RUN_ID=output.name,
        GDAY_PERFORMANCE_BUILD_REVISION=args.revision,
        GDAY_PERFORMANCE_METRICS_PATH=str(output / "metrics.jsonl"),
    )
    if args.operations is not None:
        env["GDAY_PERFORMANCE_OPERATIONS"] = str(args.operations)
    if args.task == "notes":
        env.update(
            GDAY_NOTES_CAPACITY="1",
            GDAY_NOTES_CAPACITY_BYTES=str(args.bytes),
            GDAY_NOTES_CAPACITY_WORKSPACE=args.workspace,
            GDAY_NOTES_CAPACITY_MODE=mode,
        )
    else:
        env.update(
            GDAY_PERFORMANCE="1",
            GDAY_SUMMARY_CAPACITY="1",
            GDAY_SUMMARY_INITIAL_BYTES=str(args.bytes),
            GDAY_SUMMARY_MODE=mode,
        )
    gate = output / "start.gate"
    if args.profile or args.manual_gate:
        env["GDAY_PERFORMANCE_START_GATE"] = str(gate)
    command = [
        str(binary),
        "--test-bundle-path",
        str(executable),
        "--filter",
        "NotesCapacityTests" if args.task == "notes" else "summaryCapacity",
        str(executable),
        "--testing-library",
        "swift-testing",
    ]
    manifest = {
        "schema_version": 1,
        "task": args.task,
        "mode": mode,
        "workspace": args.workspace,
        "requested_bytes": args.bytes,
        "profiled": args.profile,
        "operations": args.operations,
        "revision": args.revision,
        "bundle_sha256": sha256(executable),
        "test_bundle": str(args.bundle.resolve()),
        "app_bundle_id": bundle_id,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "command": command,
    }
    process = subprocess.Popen(
        command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    manifest["pid"] = process.pid
    atomic_json(output / "manifest.json", manifest)
    ready = threading.Event()

    def collect():
        with (output / "console.log").open("xb") as log:
            for line in process.stdout:
                log.write(line)
                log.flush()
                if b'"event":"ready"' in line:
                    ready.set()

    collector = threading.Thread(target=collect)
    collector.start()
    expired = threading.Event()

    def expire():
        expired.set()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()

    watchdog = threading.Timer(240, expire)
    watchdog.start()
    print(
        json.dumps(
            {
                "pid": process.pid,
                "app": str(app),
                "output": str(output),
                "gate": str(gate),
            }
        ),
        flush=True,
    )
    error = None
    try:
        if args.profile:
            if not ready.wait(timeout=100):
                raise RuntimeError("Workload did not reach its start gate")
            probe = capture(process.pid, output / "instruments", args.budget_root, gate)
            if not probe["requested_capture_completed"]:
                raise RuntimeError(
                    "Instruments capture ended before the requested interval completed"
                )
        process.wait()
    except KeyboardInterrupt:
        error = "Interrupted"
        if process.poll() is None:
            expire()
    except Exception as caught:
        logger.exception("Performance run failed")
        error = str(caught)
        if process.poll() is None:
            expire()
    finally:
        watchdog.cancel()
        collector.join(timeout=10)
        if collector.is_alive():
            raise RuntimeError("Output collector did not finish")
    rows = []
    metrics = output / "metrics.jsonl"
    if metrics.exists():
        rows = [
            json.loads(line)
            for line in metrics.read_text().splitlines()
            if line.strip()
        ]
    final = next((r for r in reversed(rows) if r.get("event") == "end"), {})
    completed = (
        process.returncode == 0
        and final.get("phase") in ("finished", "complete")
        and not error
    )
    result = {
        "completed": completed,
        "exit_code": process.returncode,
        "timed_out": expired.is_set(),
        "outcome": final.get("phase", "missing_end"),
        "error": error,
    }
    atomic_json(output / "result.json", result)
    print(json.dumps(result), flush=True)
    return 0 if completed else 2


if __name__ == "__main__":
    sys.exit(main())
