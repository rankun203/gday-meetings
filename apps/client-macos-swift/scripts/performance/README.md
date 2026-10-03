---
title: Reproduce macOS performance measurements
date: 2026-10-03
status: active
scope: macos-performance-scripts
---

# Performance tools

These scripts measure synthetic Notes and Summary workloads or an existing app process. Run them on macOS with the repository's Swift toolchain, Xcode Instruments, and `uv`. They do not install Gday Meetings or modify its library. Synthetic tests create temporary libraries and separate test-app identities. Run native workloads in the logged-in desktop session; a restricted shell sandbox can abort macOS application registration before measurement starts.

## Build once, measure without compilation

From the repository root:

```sh
bash apps/client-macos-swift/scripts/performance/build-tests.sh
PERF_DIR="$PWD/apps/client-macos-swift/scripts/performance"
TEST_BUNDLE="$PWD/apps/client-macos-swift/.build/out/Products/Release/GdayMeetingsTests.xctest"
RUN_ROOT=$(mktemp -d /private/tmp/gday-performance.XXXXXX)
```

Use an isolated checkout when a development bundle is running. The build script uses the same dependency/toolchain setup as the app's test script. It compiles release tests; opt-in workloads remain disabled. If the selected Swift build system uses a different product directory, pass that release `.xctest` path explicitly.

## Run a capacity test

```sh
uv run --no-project python "$PERF_DIR/run.py" notes \
  --bundle "$TEST_BUNDLE" --output "$RUN_ROOT/notes-100k" \
  --bytes 102400 --mode append --revision 'commit-and-local-change-description'

uv run --no-project python "$PERF_DIR/run.py" summary \
  --bundle "$TEST_BUNDLE" --output "$RUN_ROOT/summary-100k" \
  --bytes 102400 --mode visible --revision 'commit-and-local-change-description'
```

Start with `10240`, then `102400`, then `512000` bytes. Stop increasing a task's payload when it reaches its latency guard. Keep each comparison in a fresh process, without competing builds or captures. Notes also supports `--mode beginning`, `middle`, `style`, and `image`; Summary supports `--mode hidden` as a control. Seed size is approximate because fixtures contain whole paragraphs.

Each run records its binary hash, PID, configuration, timestamp, console output, per-second resources, per-operation durations, and final outcome. The test host is packaged from Apple's installed Swift test helper and uses a unique bundle identifier. The runner strips inherited credentials and terminal prompt variables from its child environment. Console collection happens in the runner, outside the measured process. Output directories must be new.

Exit code `0` requires both a successful test process and a completed workload. Exit code `2` means incomplete, a latency guard, timeout, or capture failure; inspect `result.json`. A successful Swift test alone can still contain a guarded performance run. A 240-second external watchdog bounds synchronous work that cannot observe the in-test guard until it returns.

## Enforce growth limits

`scaling.py` runs repeated equal-work integration batches across increasing payloads. It compares CPU time and p95 duration per operation, rather than an absolute CPU threshold. It also reports disk writes per operation and incremental peak footprint. See the [scaling contract and agent checks](../../docs/PERFORMANCE_TESTING.md) for coverage, noise handling, and known violations.

```sh
uv run --no-project python "$PERF_DIR/scaling.py" \
  --bundle "$TEST_BUNDLE" --output "$RUN_ROOT/scaling" \
  --revision 'commit-and-local-change-description'
uv run --no-project python "$PERF_DIR/scaling.py" \
  --output "$RUN_ROOT/scaling" --evaluate-only
```

Default cases cover Notes append, beginning, middle, styling, image insertion, visible Summary, and hidden Summary. Five fresh-process repeats rotate three payload sizes. Use `run.py --operations 12` for one equal-work diagnostic case. A scaling result is strict: exit 1 for detected growth, 2 for inconclusive evidence, and 0 only for covered metrics passing. CPU-only fixtures do not certify accelerators or model inference. The normal release-test build also runs deterministic `StreamingGrowthIntegrationTests`; these are enforced in macOS CI.

## Add all-device profiling

Use a separate run so profiler overhead does not contaminate the unprofiled comparison:

```sh
uv run --no-project python "$PERF_DIR/run.py" notes \
  --bundle "$TEST_BUNDLE" --output "$RUN_ROOT/notes-profile" \
  --bytes 102400 --revision 'commit-and-local-change-description' \
  --profile --budget-root "$RUN_ROOT"
```

The runner waits for the native window to settle, attaches Time Profiler, GPU, Neural Engine, and Core ML, then opens the test's start gate. Actual capture bounds, exact target PID, schemas, interval unions, hashes, and numeric values are validated before disposable files are removed. `aggregate.json` retains top inclusive CPU frames and one-second CPU bins. Missing tables fail validation; they are not zero activity. Short or target-exit traces are marked partial.

For full-library Notes, add `--workspace library --manual-gate` without `--profile`. Select **Notes** in the printed test-app path, then capture using the printed PID and gate:

```sh
uv run --no-project python "$PERF_DIR/capture.py" \
  --pid 12345 --output "$RUN_ROOT/notes-library/instruments" \
  --budget-root "$RUN_ROOT" --gate "$RUN_ROOT/notes-library/start.gate"
```

Replace the example PID and paths with the current run. To start an unprofiled manual-gate run, create its gate file after selecting Notes. The gate expires after two minutes. Do not change tabs or poll accessibility while measuring ordinary typing unless interaction overhead is the workload being tested.

## Monitor a recording

```sh
uv run --no-project python "$PERF_DIR/monitor.py" \
  --pid 12345 --output "$RUN_ROOT/recording" --duration 3600 \
  --phase transcription-and-speakers
```

Replace the PID with the running app's PID. Process CPU, footprint, RSS, disk counters, and free space are sampled every ten seconds; 20-second all-device captures start every five minutes. Use `--recording-dir` to include the two audio files' combined size. The process-start identity prevents a reused PID from merging unrelated runs. Capture/export intervals and skipped captures are recorded. Interrupt with Control-C to finish monitoring.

**The monitor does not stop or save an app recording.** Its manifest records the deadline. An active operator or agent must own the recording's stop action and verify it; an unread reminder is insufficient. See the [interaction runbook](../../docs/PERFORMANCE_TESTING.md).

All captures under one budget root share a nonblocking lock, an 8 GiB artifact interruption threshold, and a 20 GiB free-space floor. Reserve 3 GiB of scratch space before each capture. Finalization may temporarily overshoot; this is not a disk quota. Successful captures remove raw traces and CPU/device XML after verification, retaining aggregate data and the TOC. `capture.py --keep-cpu-xml` or `--keep-trace` retains detailed evidence for diagnosis. Failed captures retain evidence and a failure record; inspect and remove only those generated artifacts before retrying if they exhaust the budget.

## Analyze and draw

```sh
uv run --no-project python "$PERF_DIR/analyze.py" "$RUN_ROOT" \
  --output "$RUN_ROOT/capacity.json" --portable
uv run --no-project --with matplotlib python "$PERF_DIR/plot.py" \
  "$RUN_ROOT/capacity.json" --output "$RUN_ROOT/capacity.svg"
uv run --no-project python -m unittest discover \
  -s "$PERF_DIR" -p 'test_*.py'
```

The capacity analyzer reads `metrics.jsonl` files, preserving incomplete outcomes, achieved delivery rates, and missing probes. It also accepts explicit old JSONL/console files. The plot combines elapsed-time and payload comparisons with a device-probe table; SVG text is outlined. Inspect the companion PNG for clipping before publishing the SVG. An optional `--labels` JSON file maps build descriptions to short legend labels. Review run labels before committing portable data: the option removes local paths and unrelated process details, not user-entered names.

`monitor.py` emits separate `samples.jsonl` and per-capture aggregates for long recordings. Keep those timelines separate from the synthetic capacity figure. Append conclusions to the [endurance worklog](../../../../docs/worklogs/2026-10-02-recording-endurance.md), with the build and actual capture coverage.

## Interpretation

CPU uses one core as 100%; physical footprint differs from RSS. GPU/ANE measure active wall time, not percentage of theoretical device capacity. App GPU is part of system GPU; ANE has system-wide scope. Empty Core ML events do not establish absence of inference through other backends.

Action duration includes a run-loop opportunity and forced layout; deferred work can follow. It is not key-to-photon latency. Compare median, p95, maximum, CPU per edit, and achieved cadence. Notes requests ten updates per second but schedules relative to each prior start; its skipped counter does not capture accumulated drift. Single runs and 30-second windows establish measured cases, not universal capacity or long-session stability.

## Technical debt

The tools depend on Apple's Swift test helper path and Instruments XML schemas. They fail explicitly when those interfaces change; update discovery/schema handling and rerun metric tests after a toolchain upgrade. No installed scheduler or recording-control bridge is added. Full Markdown replacement, remaining Notes normalization costs, and long-session behavior require separate measurements when implementation changes.
