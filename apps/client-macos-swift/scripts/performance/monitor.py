#!/usr/bin/env python3
"""Sample a running macOS process and capture all devices every five minutes."""

import argparse
import ctypes as C
import json
import logging
import shutil
import signal
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from capture import capture
from trace_metrics import atomic_json

logger = logging.getLogger(__name__)


class Timebase(C.Structure):
    _fields_ = [("numer", C.c_uint32), ("denom", C.c_uint32)]


class Usage(C.Structure):
    # Darwin rusage_info_v2, including process identity and disk counters.
    _fields_ = [("uuid", C.c_ubyte * 16)] + [
        (name, C.c_uint64)
        for name in (
            "user",
            "system",
            "idle_wakes",
            "interrupt_wakes",
            "pageins",
            "wired",
            "resident",
            "footprint",
            "start",
            "exit",
            "child_user",
            "child_system",
            "child_idle",
            "child_interrupt",
            "child_pageins",
            "child_elapsed",
            "disk_read",
            "disk_write",
        )
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument(
        "--output", type=Path, required=True, help="New monitoring directory"
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=3600,
        help="Seconds; monitoring does not stop the app recording",
    )
    parser.add_argument("--phase", default="recording")
    parser.add_argument("--sample-seconds", type=float, default=10)
    parser.add_argument(
        "--capture-seconds",
        type=float,
        default=300,
        help="Capture cadence, minimum 60 seconds",
    )
    parser.add_argument("--recording-dir", type=Path)
    args = parser.parse_args()
    if (
        args.pid <= 1
        or not 0 < args.duration <= 86400
        or args.sample_seconds < 1
        or args.capture_seconds < 60
    ):
        parser.error("Invalid PID, duration, or cadence")
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    output = output.resolve()
    lib = C.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [C.c_int, C.c_int, C.c_void_p]
    base = Timebase()
    system = C.CDLL("/usr/lib/libSystem.B.dylib")
    if system.mach_timebase_info(C.byref(base)) or base.denom == 0:
        raise RuntimeError("Cannot read Mach timebase")
    tick_ns = base.numer / base.denom
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    started = time.monotonic()
    deadline = started + args.duration
    atomic_json(
        output / "manifest.json",
        {
            "pid": args.pid,
            "phase": args.phase,
            "duration_s": args.duration,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "deadline_utc": (
                datetime.now(timezone.utc) + timedelta(seconds=args.duration)
            ).isoformat(),
            "sample_seconds": args.sample_seconds,
            "capture_seconds": args.capture_seconds,
            "mach_tick_ns": tick_ns,
            "scope": "Process counters plus sampled Instruments CPU and devices. Does not control recording UI.",
        },
    )
    print(f"Monitoring PID {args.pid}; output {output}", flush=True)
    previous = identity = initial = None
    worker = None
    next_capture = started
    capture_index = 0
    events_lock = threading.Lock()

    def event(name, **values):
        with events_lock, (output / "events.jsonl").open("a") as stream:
            stream.write(
                json.dumps(
                    {
                        "utc": datetime.now(timezone.utc).isoformat(),
                        "event": name,
                        **values,
                    }
                )
                + "\n"
            )

    def profile(index):
        try:
            result = capture(args.pid, output / f"capture-{index:04}", output)
            event("capture_complete", index=index, capture=result["capture"])
        except Exception as error:
            logger.exception("Device capture failed; process sampling continues")
            event("capture_failed", index=index, error=str(error))

    try:
        with (output / "samples.jsonl").open("x") as stream:
            while not stop.is_set() and time.monotonic() < deadline:
                now = time.monotonic()
                usage = Usage()
                if lib.proc_pid_rusage(args.pid, 2, C.byref(usage)):
                    raise OSError(
                        C.get_errno(), "Cannot read process resource counters"
                    )
                if identity is not None and identity != usage.start:
                    raise RuntimeError(
                        "PID was reused; refusing to merge different processes"
                    )
                identity = usage.start
                cpu = (usage.user + usage.system) * tick_ns
                if initial is None:
                    initial = (cpu, usage.disk_read, usage.disk_write)
                percent = (
                    100 * (cpu - previous[1]) / ((now - previous[0]) * 1e9)
                    if previous
                    else None
                )
                previous = (now, cpu)
                if now >= next_capture:
                    next_capture += (
                        int((now - next_capture) // args.capture_seconds) + 1
                    ) * args.capture_seconds
                    if worker and worker.is_alive():
                        event("capture_skipped_busy", index=capture_index)
                    else:
                        worker = threading.Thread(target=profile, args=(capture_index,))
                        worker.start()
                    capture_index += 1
                audio_bytes = None
                if args.recording_dir:
                    audio_bytes = sum(
                        (args.recording_dir / name).stat().st_size
                        for name in ("microphone.opus", "system.opus")
                        if (args.recording_dir / name).is_file()
                    )
                row = {
                    "utc": datetime.now(timezone.utc).isoformat(),
                    "phase": args.phase,
                    "elapsed_s": now - started,
                    "process_cpu_pct": percent,
                    "process_cpu_ns": cpu - initial[0],
                    "physical_footprint_bytes": usage.footprint,
                    "resident_bytes": usage.resident,
                    "disk_read_bytes": usage.disk_read - initial[1],
                    "disk_write_bytes": usage.disk_write - initial[2],
                    "audio_bytes": audio_bytes,
                    "free_bytes": shutil.disk_usage(output).free,
                    "profiling": bool(worker and worker.is_alive()),
                }
                stream.write(json.dumps(row, allow_nan=False) + "\n")
                stream.flush()
                stop.wait(min(args.sample_seconds, max(0, deadline - time.monotonic())))
        event(
            "measurement_deadline"
            if time.monotonic() >= deadline
            else "monitor_stop_requested"
        )
        print(
            "Monitoring ended. Stop and save the recording through the app if required.",
            flush=True,
        )
    except Exception as error:
        event("monitor_error", error=str(error))
        raise
    finally:
        if worker:
            worker.join()
        event("monitor_stopped")


if __name__ == "__main__":
    main()
