---
title: Recording and summary performance evaluation
date: 2026-10-02
status: planned
scope: swift-app-performance
---

# Problem

Live transcript updates can freeze the interface as a recording grows. The user also reports about 100% CPU during summary generation. The summary report has not yet been reproduced under controlled measurement; CPU percentage alone does not identify a main-thread stall or its cause.

Related evidence:

- [Long recording performance](2026-10-02-live-recording-performance.md) measured component improvements but retained historical comparisons and indexes. It did not establish sustained application CPU or recognition quality.
- [Resource audit](2026-09-28-resource-audit.md) established low CPU for a paused, completed summary in isolated Preview. That result does not cover active summary generation.
- [Summary task isolation](2026-09-28-summary-task-isolation.md) validates task independence and completion behavior, not streaming rendering cost.

# Evaluation sequence

Finish, test, and push the incremental transcript feature first. Then run this evaluation against that exact commit and a baseline commit on the same Mac. Keep the user's library and recording separate from profiling fixtures. Use synthetic Chinese and English speech/text; keep traces outside the repository because process captures may include local paths or content.

Record commit, release configuration, macOS/Xcode version, hardware, display refresh rate, window size, selected model/preset, power state, and fixture/event rate. Warm models and fonts before steady-state measurements; report startup separately. Repeat each comparison three times without competing builds. Report medians and variation, not one favorable run.

# Workloads

| Area | Cases | Questions |
| --- | --- | --- |
| History scaling | Seed 5, 60, and 180 minutes; replay the same next 60 seconds | Does update cost stay independent of frozen history? |
| Speaker continuity | One Chinese speaker; frequent turns; two simultaneous sources; short silence and uncertain activity | Are carried labels stable, with no unresolved-badge fragmentation? Are real speaker changes preserved? |
| Delayed processing | Delay diarization; stop its output; flush at stop; reset after an audio gap | Is active work bounded? Does the cutoff persist the same effective labels on reopen? |
| Live interaction | Follow Live; scroll into history; select/edit a passage; open speaker picker; switch tabs | Do background updates preserve scroll, selection, and input responsiveness? |
| Recording pipeline | Capture only; transcription; labeling; both; association; window hidden | Separate UI overhead from audio, ASR, inference, and embedding work. |
| Summary generation | Short/long transcript inputs; short/long streamed outputs; English/Chinese; citation-heavy, list, and table content | Locate CPU cost in input preparation, stream decoding, publication, Markdown parsing/layout, citations, persistence, or indexing. |
| Summary visibility | Summary visible; another tab visible; another meeting selected; window hidden | Does invisible summary output still trigger expensive rendering or library-wide updates? |
| Summary lifecycle | First token, steady stream, final save, cancellation, failure, regeneration, completed idle | Does CPU settle after completion/cancellation? Are tasks and UI responsive throughout? |
| Combined work | Generate a summary for a saved synthetic meeting during another synthetic recording | Do task publication and rendering interfere with live audio or transcript updates? |
| Storage/recovery | Slow writes, writer failure, interrupted final record, reopen, Stop & Save | Are errors visible and saved labels/raw evidence recoverable without repeated historical rewrites? |

Use a deterministic local streaming provider for repeatable summary chunk timing and output. Compare small frequent chunks with batched chunks at the same total text rate. Measure an actual configured provider separately only with an explicitly chosen synthetic fixture; network wait and provider generation time are distinct from local rendering cost. Never reuse the user's screenshot text as a fixture.

## Installed-app follow-up

After release validation, install the final build in Applications without replacing a running recording. The user will open it, resolve permission dialogs, and start the recording. First capture short transcript-only and summary-only sessions, then combined work. For a multi-hour recording, use lightweight process observations between 30–60-second Instruments windows near 5, 30, 60, and 120 minutes and when a slowdown occurs. Do not keep a high-volume Instruments recording active for hours.

Limit this profiling session's trace artifacts to 5 GiB and preserve at least 20 GiB free disk space. Check free space and trace size before and after each window; during capture, stop the profiler if either budget is reached. Leave the meeting recording running. Keep measured summaries and the most useful short traces; remove only disposable traces created for this evaluation when rotating the budget. Account separately for the app's recording/journal growth and report its observed bytes per minute. These are profiling limits, not a guarantee about other processes' disk usage.

# Measurements

- **Time Profiler and SwiftUI:** main-thread stacks, view/platform updates, publication causes, event-to-display latency, and p50/p95/p99 update duration. Native transcript layout must be inspected as well as SwiftUI body work.
- **Animation Hitches and hangs:** scroll/frame cadence, longest main-thread stall, and delayed input while recording or generating summaries.
- **Allocations and process usage:** CPU expressed as a percentage of one core, CPU time per event/second, physical footprint, allocation rate, retained active-state size, and growth after warm-up. Transcript storage can grow with content; repeated work per event should not.
- **File Activity:** bytes and write count per new transcript event, journal backlog, summary save/index cost, finalization latency, and recovery behavior.
- **Audio and inference:** dropped input, consumer backlog, inference real-time factor, and speaker-output delay. UI-only replay cannot validate model accuracy or hardware continuity.

Use signposts/counters where necessary to distinguish receive, attribution, freeze, display assembly, native update, journal append, summary parse/layout, and final save. Collect uninstrumented timings too: detailed allocation or system tracing changes workload cost.

# Acceptance criteria

These are proposed evaluation gates, not measured results:

- Ordinary live ticks perform zero historical phrase reattributions and zero historical row regenerations/reloads. The affected tail remains bounded under a monologue and stalled diarization. Explicit edits, navigation, resize, or appearance changes may legitimately redraw existing content.
- Across seeded history sizes, per-tick cost and transient allocation stay approximately flat. Investigate any repeatable increase over 20%, while reporting absolute times and measurement noise.
- Aim for p95 main-thread transcript update work below 8 ms and no transcript/summary-caused input stall of 100 ms or more during steady state. Report frame deadlines for the actual display; an 8 ms update alone does not prove hitch-free 120 Hz rendering.
- Saved and reopened effective labels match the live finalized result. Raw word evidence retains unresolved attribution and remains separate from carry-forward decisions.
- Completed/cancelled summary CPU returns near its pre-task baseline. Explain sustained one-core usage with stacks before prescribing a fix; a background worker at 100% is different from a blocked main thread.
- Report all failed cases, unsupported profiling tools, untested devices, and confidence limits alongside results.

Apple's [responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) motivates the 100 ms interaction limit. Its [SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) explains view/platform update tracks and cause-and-effect inspection.

# Progress and tooling

- Read the related recording, resource-audit, and summary-isolation worklogs.
- Instruments templates are available, including Time Profiler, SwiftUI, Animation Hitches, Allocations, and File Activity.
- On macOS 26.6.2 with Xcode 27.0 (27A266a), the first `xctrace record` attempt crashed with a missing weak symbol in `Devices.xrplugin`. The user completed the additional installation requested when opening Instruments. A subsequent 15-second Time Profiler capture of isolated synthetic Preview succeeded at `/private/tmp/gday-live-baseline-idle-installed.trace`. This establishes recorder availability, not live-update performance: the baseline fixture has static transcript text.
- Active summary generation measurements are pending. The reported CPU usage is recorded as a hypothesis to reproduce, not a diagnosed Markdown or model issue.
- Code inspection identifies two paths to measure: `MeetingIntelligence` publishes accumulated summary text through `MeetingStore.summaryDrafts`; changed text in `NativeMarkdownReadingView.updateNSView` renders and replaces the complete attributed document and refreshes its ranges. These operations are candidates for growing streaming cost, not proof of the reported CPU cause. Compare visible and hidden Summary before choosing a repair.

# Technical debt

None introduced by this plan. Do not substitute a static Preview or component benchmark for sustained end-to-end evidence.
