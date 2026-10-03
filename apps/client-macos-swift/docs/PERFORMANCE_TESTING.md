---
title: Test resource scaling and app interactions
date: 2026-10-03
status: ready
scope: macos-performance-runbook
---

# Resource scaling and app interactions

Start with automated scaling tests. Use agent-led testing for behavior the fixtures cannot establish: perceived input delay, visual correctness, real capture routes, provider streaming, and accelerator activity. Append measurements to the [endurance worklog](../../../docs/worklogs/2026-10-02-recording-endurance.md); keep real meeting content and raw traces outside the repository.

## Scaling contract

Compare **the same amount of new work** after increasing accumulated history. Total recording bytes and stored text may grow; CPU per audio second or edit, incremental writes, mutable queues, and work on the visible region should remain bounded. Initial loading, full export, search, and edits that deliberately affect the whole document are separate workloads. A large image has an unavoidable decoding cost; hold its dimensions and format fixed when testing growth in surrounding Notes.

| Lane | Automated coverage | Pass condition |
| --- | --- | --- |
| Default CI | Real stream, speaker-attribution and display-cache updates after 1, 10, and 100 minutes of synthetic two-source history; delayed labels included | Bounded attribution/rebuild counts and hot rows; the first frozen row stays unchanged; all final rows survive |
| Default CI | Real capture fan-out to transcription and labeling queues, with increasingly stalled consumers | PCM stays within two seconds per queue; bounded loss records preserve overload evidence |
| Default CI | Continuous dual-track Opus encoding, metering, and echo processing; fixed windows after 1, 10, and 100 encoded seconds | Bounded page writes per window; output is appended, not rewritten with accumulated history |
| Release scaling | Notes append/start/middle edits, local Markdown styling, image insertion; visible and hidden Summary streams at 10/100/500 KiB | Repeated equal-work CPU/operation, p95 operation duration, and writes/operation stay within the growth budget |
| Hardware recording | Real microphone/system capture, Apple transcription and installed speaker models | Measure matched early/middle/late windows with CPU, memory, disk, GPU/ANE and completed-audio coverage; never substitute synthetic labels for inference coverage |

The deterministic integration suite runs in the macOS build matrix through `build-tests.sh`. It exercises production components without model downloads or permission prompts. It does not prove the model's internal caches, GPU/ANE cost, actual device delivery, or complete-window rendering are bounded.

Run the strict release lane separately on a quiet desktop:

```sh
bash apps/client-macos-swift/scripts/performance/build-tests.sh
PERF_DIR="$PWD/apps/client-macos-swift/scripts/performance"
TEST_BUNDLE="$PWD/apps/client-macos-swift/.build/out/Products/Release/GdayMeetingsTests.xctest"
uv run --no-project python "$PERF_DIR/scaling.py" \
  --bundle "$TEST_BUNDLE" --output /private/tmp/gday-scaling-new \
  --revision "$(git rev-parse HEAD)"
```

Use a new output directory and an isolated checkout when a development bundle is running. The runner uses five fresh processes per case and size, rotates size order, and applies twelve identical operations per run. All cases receive the same operation count, fragment or image, viewport, and binary. A fixed upper duration and external watchdog prevent a slow case from hanging indefinitely. Incomplete work is not a passing measurement. Narrow a diagnostic run with `--cases notes:middle summary:visible`; at least three repeats and three sizes spanning 10× are required.

The default budget is **2× cost over the tested history range**, not two times a particular Mac's CPU percentage. A comparison fails when the larger case's lower quartile exceeds twice the baseline's upper quartile. It passes when the larger upper quartile stays within twice the baseline's lower quartile; overlap is inconclusive. This repeat-spread rule reduces noisy verdicts but is not a statistical confidence interval or proof of constant asymptotic cost. Unit tests verify that uniform device-speed changes preserve verdicts and that linear/quadratic growth fails. Do not increase the budget to accommodate a regression.

`scaling-report.json` records every comparison, failed/incomplete run, release binary hash, final payload and counter scope. Exit **0** means the measured CPU/latency/disk contract passed, **1** means a detected violation, and **2** means missing or noisy evidence. Average CPU is insufficient: a saturated app can remain at 100% while completing fewer actions. The gate compares CPU time per operation and checks equal delivered work. CPU and disk totals include the five-second settling/save window, so postponing work cannot evade the gate. Total footprint is allowed to grow with document storage; incremental peak footprint is reported, but allocator retention makes it unsuitable as a universal allocation bound. Missing GPU/ANE data is unmeasured, never zero or an implied pass.

Current large-document Notes and Summary paths are known to violate the desired flat-cost contract. The release lane is an explicit strict test, not a silently passing benchmark or an expected-failure exemption. Keep it out of the ordinary build gate until the product paths satisfy it; deterministic bounded-work checks remain enforced on every macOS build. Use failures to locate repeated work, repair it, and rerun the same cases.

## Agent-led checks

An agent should run and interpret the automated report first, then spend UI time on what it cannot prove:

- Compare typing at the beginning, middle, and end of large Notes. Use composition input, selection replacement, undo/redo, and rapid typing; watch caret movement, dropped/reordered text, scroll jumps, and visible delay. Verify saved/reopened content and timestamps.
- Paste images into large Notes, resize and undo them, then switch read/edit. Verify image identity, position, sharpness, aspect ratio, and selection. Use a fixed image for resource comparisons, then separately vary pixel dimensions and asset count.
- Observe actual provider fragments while Summary is visible and hidden. Check incomplete Markdown, lists, code fences, citations, scrolling/selection, cancellation and final persistence. A synthetic stream does not cover network cadence or arbitrary Markdown block boundaries.
- Switch meetings, tabs and applications during recording and streaming. Capture the first frame after returning, blank content, focus, transient stalls, and whether controls remain usable. Locate controls before profiling to avoid charging accessibility polling to the app.
- Exercise real input devices, route changes, silence, overlap, and repeated fixed audio with installed models. Check transcript coverage and speaker continuity as well as resources; lower resource use caused by dropped work is a failure.

Do not repeat manually what automated counters already establish. Record the build, expected and observed behavior, screenshots, actual action/capture timestamps, and unavailable permissions/providers. For a visual stall, use UI/hang or allocation profiling; CPU alone cannot establish key-to-photon latency. For scaling comparisons, warm the selected models first, then loop the same authorized fixed audio at the same cadence. Keep speakers, audio format, device routes, model presets, and visible content constant; compare equal completed-audio windows after warm-up, midway, and near the end. Record gaps and dropped work. Separate changing-source endurance observations from this controlled test. The following one-hour schedule covers the hardware and interaction lane.

## Prepare

- Record installed build/commit, hardware, macOS/Instruments versions, and provider/model choices. Check newer source fixes separately; keep the installed build unchanged during comparisons.
- Enable **microphone + system audio**, **voice processing**, **Transcribe**, **Label Speakers**, and live **Speaker Association**. Verify provider readiness and both audio sources.
- Temporarily disable automatic after-recording Summary and to-do generation; record their original settings for restoration.
- Queue at least 75 minutes of authorized meeting audio with a lightweight player such as `ffplay`. Verify automatic advancement. Avoid competing builds; log any background workload.
- Start 10-second sampling of app CPU, physical footprint, RSS, disk I/O, free space, and readable speech-service CPU. Prepare Instruments before starting the recording.

## Schedule

| When | Action | Verify |
| --- | --- | --- |
| Start | Start a separate evaluation recording and set a 60-minute stop deadline. | Timestamp, settings, audio input. |
| Every 5 minutes, through minute 55 | Capture 20 seconds of Time Profiler, GPU, Neural Engine, and Core ML, with the transcript visible. | Actual trace bounds and per-device values. |
| After minute 55 capture | Append 40 short synthetic Notes paragraphs through repeated typing; paste two synthetic images, roughly 2K and 4K. Use separate short typing and paste captures. | Input count/size, action times, saved text/images, responsiveness. |
| At minute 60 | Stop and save with the control already located and tracing active. | Actual click/finalization times, CPU/memory peaks, both audio files and durations. |
| After save | Switch Notes read/edit, Transcript, Summary, another evaluation meeting, and back. | Visible content, blank states, stalls, timestamps. |
| Provider available | Generate Summary; observe output, switch tabs and meetings during streaming, then repeat after completion. | First output/completion, persisted Summary, whether each interaction occurred during streaming. |
| Finish | Restore settings; stop players, samplers, profilers, and keep-awake processes. | Saved recording and verified shutdown. |

A watchdog must own the actual stop action and verify it; a reminder to an inactive parent is insufficient. Log delays rather than silently extending the planned hour.

## Instruments and storage

Attach **Time Profiler + GPU + Neural Engine + Core ML** to the installed app. For a single prepared capture:

```sh
APP_PID=$(pgrep -x GdayMeetings) # Confirm exactly one PID.
TRACE_DIR=$(mktemp -d /private/tmp/gday-performance.XXXXXX)
xcrun xctrace record --template 'Time Profiler' \
  --instrument GPU --instrument 'Neural Engine' --instrument 'Core ML' \
  --attach "$APP_PID" --time-limit 20s --output "$TRACE_DIR/sample.trace"
xcrun xctrace export --input "$TRACE_DIR/sample.trace" --toc \
  --output "$TRACE_DIR/sample-toc.xml"
```

Export CPU/device tables using schemas in that TOC. Validate numeric aggregates, actual time bounds, and provenance before deleting intermediates. Keep anomaly traces when needed; preserve recordings and unverified evidence. Run only one capture/export worker at a time.

Use an **8 GiB artifact interruption threshold** and **20 GiB free-space floor**, checked throughout capture/export. Finalization can overshoot: these are not hard quotas. Prior 30- and 90-second interactive captures exceeded the budget. Start with 20-second windows and record skipped intervals if export overlaps the next slot.

Focus the editor or locate controls before capture. Compare action timestamps with actual trace bounds. For Summary, capture active output as well as request startup; short captures can miss the CPU peak. Use separate UI/hang or allocation profiling when CPU samples cannot explain a stall or memory spike.

For Summary diagnosis, add a separate **90–150-second CPU-only Time Profiler capture** covering the whole request and settling period. Keep device probes short; combining all instruments for a long capture previously failed during finalization. Compare Summary visible, Summary hidden behind Notes, and a longer recording. Avoid accessibility polling during at least one request, and label automation overhead in interaction captures.

Align CPU samples with `data-events.jsonl` provider receipt times (milliseconds since 1970) and `tasks.jsonl` task times (seconds since 2001). Provider elapsed time includes network waiting; managed-task time also includes local preparation and saving. Neither measures UI completion or CPU execution time. Report sampled CPU-seconds separately, use complete one-second bins for peaks, and do not infer first-token time when logs lack it. Keep identifiers and content out of exported results.

## Provider availability and reporting

Use the configured, authorized Summary provider. If unavailable, unconfigured, or awaiting data-sharing approval, complete local Notes/navigation tests and mark Summary **not run**, with the reason. Retry separately; do not silently substitute a provider or count an idle request as generated output.

Report recording and interaction timelines as separate SVGs with outlined fonts. Keep gaps open. CPU uses one core as 100%; memory means physical footprint. GPU/ANE values are active wall time over actual trace duration, not device-capacity utilization. App GPU is included in system GPU; ANE may be system-wide. Do not add device percentages; empty Core ML tables do not establish absence of model execution.

Prior repeat reference: approximately **47% app CPU**, **22.5% main-thread CPU**, **0.78–0.84% app GPU active time**, and **15.7–17.0% system ANE active time**. These are descriptive, not pass/fail thresholds. Its roughly 1 GiB save footprint was measured on an older build; source fixes need a new measured run. See the [evaluation plan](../../../docs/worklogs/2026-10-02-performance-evaluation-plan.md) for responsiveness criteria.

## Payload and typing capacity

Use the [saved performance tools](../scripts/performance/README.md) to build, run, profile, analyze, and draw repeatable tests. Run the opt-in `NotesCapacityTests` and `SummaryPerformanceTests.summaryCapacity` in release configuration, in separate fresh processes. Build first and keep compilation outside measurement windows. These fixtures use temporary libraries and synthetic content; they do not require a provider or use the installed library.

| Workload | Environment |
| --- | --- |
| Notes | `GDAY_NOTES_CAPACITY=1`, `GDAY_NOTES_CAPACITY_BYTES=102400`, `GDAY_NOTES_CAPACITY_WORKSPACE=component`, `GDAY_NOTES_CAPACITY_MODE=append` |
| Visible Summary | `GDAY_PERFORMANCE=1`, `GDAY_SUMMARY_CAPACITY=1`, `GDAY_SUMMARY_INITIAL_BYTES=102400`, `GDAY_SUMMARY_MODE=visible` |
| Hidden Summary control | The Summary settings above with `GDAY_SUMMARY_MODE=hidden` |

Start at 10 KiB and 100 KiB, then try 500 KiB (`512000` bytes) when the smaller runs complete. Keep cadence and inserted fragment size constant within each task. Notes inserts one character at 10 Hz; Summary publishes one fixed paragraph at 10 Hz. Each run grows for 25 seconds and holds for five seconds. Notes also flushes persistence. Compare task costs without implying that one typed character equals one Summary paragraph.

Set `GDAY_PERFORMANCE_RUN_ID`, `GDAY_PERFORMANCE_BUILD_REVISION`, and an absolute `GDAY_PERFORMANCE_METRICS_PATH` for provenance. JSONL metrics include action times, payload sizes, CPU counters, footprint, and disk counters. Collect stdout through a separate process so logging writes are not charged to the measured process. The optional metrics file is flushed after the final sample. Require a successful test result and a final `end` event with phase `finished` or `complete`; exclude partial runs from capacity comparisons.

For synchronized Instruments capture, set `GDAY_PERFORMANCE_START_GATE` to a new, absent temporary path. Wait for its `.ready.json` sidecar, attach Instruments to that PID, and create the gate file only after recording starts. The gate times out after two minutes. For full-window Notes, use `GDAY_NOTES_CAPACITY_WORKSPACE=library` and select **Notes** before opening the gate. Use a normally launched test host when UI automation needs application registration. Remove inherited `PROMPT` and `RPROMPT` variables before launching; terminal escape characters can make the Instruments TOC invalid XML.

Measure unprofiled capacity separately from instrumented diagnosis. Repeat representative runs to distinguish consistent costs from noise. Compare CPU over elapsed time, peak footprint and writes over payload size, and median/p95/maximum edit-and-layout time in one aligned SVG. Keep app GPU, system GPU, and system ANE scopes explicit. Do not fill missing probes with zero.

The Notes action timer covers insertion, a 1 ms run-loop opportunity, and forced layout/drawing. Deferred styling can occur afterward; this is an operation/layout proxy, not key-to-photon latency. Use the 16.7 ms ordinary-edit target to guide investigation, then verify perceived responsiveness in the installed app. Neither a 30-second test nor a single payload establishes a universal content limit or long-session stability.

## Technical debt

Recording control remains manual; the saved monitor records deadlines and resource use but does not stop or save recordings. The reusable tools accept an explicit PID, validate device aggregates, and enforce capture budgets. Their Swift helper path and Instruments XML schemas require validation after toolchain upgrades. Original private scripts are historical evidence, not the rerun interface.
