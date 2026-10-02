---
title: Recording and summary performance evaluation
date: 2026-10-02
status: in-progress
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
| Live interaction | Follow Live; scroll into history; select/edit a passage; open speaker picker; switch tabs; return after another app covers the window | Do background updates preserve scroll, selection, and input responsiveness? |
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

# First installed-app measurements

The user authorized replay from an existing local playback page after clearing app permissions. A separate evaluation recording captures system audio only, with live transcription, speaker labeling, and existing speaker association enabled. A separate notes-only meeting contains synthetic text for summary evaluation. No existing summary was replaced. Meeting content, names, library identifiers, and raw traces are excluded from this repository.

Environment: MacBookPro18,4 with 64 GiB memory, macOS 26.6.2, validated release containing feature commit `170a050`. All three release CI jobs passed (macOS 15, 26, and 27 preview). The installed source snapshot also contains the concurrent provider-icon edits tested in the same isolated build; those changes were excluded from the transcript feature commit. Raw profiling artifacts are in `/private/tmp/gday-performance-20261002`.

| Capture | Duration | Sampled process CPU | Sampled main-thread CPU | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Idle setup | 20 s | 15 ms | 13 ms | Mostly accessibility queries; no live workload. |
| Early live transcript | 45 s | 14.474 s | 10.174 s | Includes resize and accessibility activity; unsuitable as a clean steady-state baseline. |
| Same recording, Notes visible | 30 s | 5.262 s | 1.675 s | About 17.5% of one core overall and 5.6% on the main thread. |
| Synthetic summary during recording | 45 s | 12.080 s | 6.012 s | Small output; substantial accessibility inspection overhead. |
| Quiet live transcript near eight minutes | 45 s | 14.267 s | 9.582 s | No UI automation during capture; about 31.7% of one core overall and 21.3% on the main thread. |

Time Profiler weights are statistical CPU samples, not wall-clock task latency. Inclusive stacks overlap and must not be added. These are single windows with different speech content, not repeated matched benchmarks. Separate speech services and browser playback are outside the attached app's CPU totals.

The early live trace attributes 4.739 s inclusively to SwiftUI size fitting, 2.418 s to hosting-view minimum size, and 1.834 s to hosting size constraints. Direct transcript display refresh accounts for 304 ms, native transcript updates 167 ms, and stream attribution 12 ms. Word tokenization accounts for 263 ms of display refresh. Even after excluding direct resize/accessibility stacks, substantial size-fitting work remains. The quiet capture contains only 17 ms of accessibility work and no resize stacks. It records 4.752 s in size fitting, 2.478 s in hosting minimum size, 2.160 s in hosting size constraints, 346 ms in transcript display refresh (316 ms word tokenization), 271 ms in native transcript updates, and 25 ms in stream attribution. This confirms that visible transcript layout CPU remains significant without inspection. Adaptive layouts and hosting-size invalidation are investigation candidates, not yet a proven specific view defect.

The small synthetic summary completed. Markdown rendering accounts for 13 ms, versus 2.425 s of accessibility inspection; table cleanup coincides with those inspection bursts. Process samples briefly exceeded one core, but this does not reproduce sustained summary-rendering CPU. A larger deterministic stream is still required: fixed 1k, 10k, and 50k character outputs at the same chunk cadence, visible and hidden, with no accessibility polling during capture. Source inspection still shows complete Markdown rendering and replacement on each changed output.

The early and quiet Time Profiler captures reported no potential hangs at the configured 250 ms threshold. This does not establish the proposed 100 ms interaction target, frame smoothness, or multi-hour stability. Switching Notes/Summary and returning to the live transcript worked, and speaker carry-forward removed unresolved badges in observed live rows. Model identity changes and recognition errors remain separate quality concerns.

At about twelve minutes, audio and journal artifacts totaled approximately 14.4 MiB. Over the last 129-second interval they grew by 2.7 MiB, approximately 1.3 MiB/minute; longer runs and different speech can change that rate. Free disk remained approximately 172 GiB. Time Profiler artifacts remained below 250 MiB before the SwiftUI capture; temporary capture storage later peaked around 735 MiB, with about 170 GiB free, still below the session limits. The 30-second SwiftUI capture emitted an Instruments type-parser warning for an optional closure type. Its separate layout table is empty; update descriptions are available, but some hierarchy entries say the view predates tracing, limiting exact view attribution. Final trace/export storage was approximately 634 MiB.

The SwiftUI capture reports 404 hitch events for the app in 30 seconds: 333 at about 8.3 ms, 47 at 16.7 ms, 19 at 25 ms, three at 33.3 ms, and two at 41.7 ms. These are frame hitch durations, not input latency or independent application freezes; detailed instrumentation adds overhead. The update table records 224 RootGeometry events totaling 693 ms, 400 native-transcript platform-child events totaling 169 ms, and 400 live-transcript body events totaling 39 ms. Event durations can overlap. This reinforces the need to investigate repeated root/layout work rather than treating body evaluation or history attribution as the entire cost.

Scrolling into history paused Follow Live, and selecting Follow Live returned to the bottom while recording continued. At the end of this initial profiling pass, playback and the evaluation recording remain running; all Instruments captures are stopped. No unattended multi-hour monitor has been started.

## Next controlled work

A user-reported blank live transcript after returning from another app is documented in the [endurance results](2026-10-02-recording-endurance.md). Reproduce foregrounding with 5, 60, and 120 minutes of synthetic history, both at the live edge and while reading older rows. Start the UI/hang capture before covering the window, then return after 30 seconds and after several minutes. Compare ordinary app switching, minimization, and meeting switching; record time to visible content, main-thread stalls, frame hitches, and view invalidation. Keep pointer and accessibility inspection out of the quiet interval. A low ten-second CPU average cannot rule out a brief blank frame or stalled main thread.

1. Isolate hosting-size invalidation and adaptive fitting in a synthetic recording preview. Compare the existing layout with one targeted change at a time; preserve window resizing and narrow-window behavior. Do not infer the exact responsible view instance from opaque framework stacks.
2. Cache recent-word highlight ranges when recognition text/timing are unchanged, then measure tokenizer and native update cost again.
3. Reproduce long summary streaming with deterministic output sizes and chunk cadence. Separate visible rendering, hidden publication, completion, and cancellation.
4. Repeat matched runs and capture frame/input latency before claiming the 100 ms target. Continue 30/60/120-minute checks with sustained audio and disk guards; this initial session does not establish multi-hour behavior.

# Technical debt

None introduced by this plan. Do not substitute a static Preview or component benchmark for sustained end-to-end evidence.
