---
title: Repeat the speaker-processing and interaction test
date: 2026-10-03
status: ready
scope: macos-performance-runbook
---

# One-hour recording, Notes, and Summary test

Repeat the final speaker-enabled run using this checklist. Append measurements to the [endurance worklog](../../../docs/worklogs/2026-10-02-recording-endurance.md); keep real meeting content and raw traces outside the repository.

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

## Provider availability and reporting

Use the configured, authorized Summary provider. If unavailable, unconfigured, or awaiting data-sharing approval, complete local Notes/navigation tests and mark Summary **not run**, with the reason. Retry separately; do not silently substitute a provider or count an idle request as generated output.

Report recording and interaction timelines as separate SVGs with outlined fonts. Keep gaps open. CPU uses one core as 100%; memory means physical footprint. GPU/ANE values are active wall time over actual trace duration, not device-capacity utilization. App GPU is included in system GPU; ANE may be system-wide. Do not add device percentages; empty Core ML tables do not establish absence of model execution.

Prior repeat reference: approximately **47% app CPU**, **22.5% main-thread CPU**, **0.78–0.84% app GPU active time**, and **15.7–17.0% system ANE active time**. These are descriptive, not pass/fail thresholds. Its roughly 1 GiB save footprint was measured on an older build; source fixes need a new measured run. See the [evaluation plan](../../../docs/worklogs/2026-10-02-performance-evaluation-plan.md) for responsiveness criteria.

## Technical debt

This is a manual runbook, not an installed scheduler. Original private scripts contain machine-specific paths and a PID; do not assume they exist or reuse them unchanged. A reusable harness should discover the process, validate device aggregates, enforce storage limits, and verify scheduled actions.
