---
title: Startup and subsequent UI activity
date: 2026-10-07
status: measured-with-inferences
scope: macos-user-journey-performance
journey_id: app-startup
---

# Startup and subsequent UI activity

## Findings

The supplied launch trace contains 53.008 seconds of startup and later foreground activity. The initial frame lifecycle interval ends at trace second 2.036, and Foreground begins at 2.060. These are lifecycle markers, not proof the library and selected meeting were usable. A background index rebuild is sampled between 2.229 and 20.569 seconds. Later stacks identify transcript work, Notes image/layout work, and General Settings activity; exact clicks and screen contents cannot be recovered without a recording or interaction markers.

The capture contains 43.041 seconds of sampled app CPU: 19.372 seconds on the main thread and 23.669 seconds on workers. CPU samples are statistical weights; they are not wall-clock operation duration. The Hangs instrument reports 36 intervals over 100 ms, totaling 6.518 seconds, with a maximum of 514.6 ms. Initial startup has no reported hang interval before 2.060 seconds; pre-launch work can still delay the first frame.

## Reconstructed sequence

All times are relative to the trace start, 16:58:43.471 Melbourne time. The trace reports a launched process. The template was Blank with several instruments added, rather than the standard App Launch template.

| Trace interval | Evidence | Interpretation |
| --- | --- | --- |
| 0.745–0.767 s | System/static initialization lifecycle events | Framework/runtime initialization is underway. Earlier time is not fully attributed by these events. |
| Approximately 0.925–1.475 s | Voice-library load stacks | Eager voice record loading and file-revision scanning block the main thread during store construction. Bounds are sample envelopes, not exact operation start/end. |
| 1.499–2.036 s | AppKit initialization, scene creation, callbacks, initial frame lifecycle | The app builds its first scene/frame. Foreground begins at 2.060 s. |
| Approximately 2.229–20.569 s | Worker `LibraryIndex.rebuild` stacks | A full library index rebuild runs concurrently with foreground UI work. Why this launch required a full rebuild is not established. |
| 5.353–32.755 s, intermittent | Native transcript table stacks | Transcript rows are built and measured. The largest dense layout burst is around 9–13 s. This does not identify particular meetings. |
| 15.112–25.969 s, intermittent | Notes image/layout stacks | Notes-related presentation work is present. Other Markdown rendering stacks overlap this broader interval. |
| 24.583–25.088 s | 505.6 ms hang; only 4 ms main-thread CPU samples | Likely a non-CPU stall or a sampling gap. Excluded from the current optimization scope at the user’s request. |
| 32.780–33.294 s | 514.6 ms hang; 502 ms main-thread CPU samples; General Settings and layout stacks | A busy-main-thread stall around General Settings construction/update. Layout work is confirmed; the initiating mutation/constraint is not. |
| 44.446–44.728 s | 281.9 ms microhang; 278 ms main-thread CPU samples | Another busy layout interval with General Settings present. |
| 46–53.008 s | Approximately 0.333 s main-thread and 0.149 s worker CPU samples | Sampled CPU is much lower toward the end. This is an observation, not a measured readiness time. |

The animated reconstruction uses half-second CPU bins, measured lifecycle and hang intervals, and explicitly labeled sample spans for other work. Sample spans can contain gaps and do not represent continuous execution or visibility of a screen.

## Expensive operations and optimization order

### 1. Remove synchronous voice-library loading from the launch path

`MeetingStore.init` eagerly accesses `voicePreparation`, which constructs the lazy voice store. `VoiceLibraryPersistence.load` accounts for approximately 494 ms of main-thread CPU, including 301 ms in `captureFileRevisions`; record reading contributes another overlapping 193 ms. File revision inspection contributes about 269 ms across the capture. These inclusive weights overlap.

Load voice metadata and task checkpoints on a serialized storage worker, then publish a coherent snapshot on the main actor. Make readiness explicit so voice actions wait for the snapshot without blocking navigation. Preserve crash recovery, revision validation, write ordering, and read-only error behavior. Merely wrapping the main-actor initializer in `Task` would retain the problem. Defer initialization until needed only if task recovery can still restore correct state independently.

### 2. Reduce full index rebuild cost and publication frequency

Worker rebuild stacks account for approximately 17.671 CPU seconds. Search passage extraction accounts for 5.676 seconds, `NotesReadingDocument.searchableText` for 3.273 seconds, `MarkdownSelectionSourceMap.init` for 2.534 seconds, and regex construction for 2.470 seconds. SQLite execute paths contribute roughly 3.797 seconds; staging publication contributes 2.125 seconds. Inclusive weights overlap and must not be added.

Current rebuild code reads each meeting and rebuilds search passages. Its Markdown search path constructs a source-selection map for each block/cell. Source-selection offsets are needed for editor selection, but not necessarily for plain search text. Reuse compiled constant regexes, and provide equivalent plain-text extraction without unnecessary source-position mapping. Preserve link/image/code semantics and CJK output with synthetic equivalence cases.

Investigate why this launch entered a full rebuild: index incompleteness, cursor recovery, or broad filesystem events can require it. Do not skip a required recovery scan. Reuse unchanged search content through validated source revisions, and reconcile changed files when safe. Rebuild progress currently schedules a main-actor report for each processed recording; coalesce progress while preserving useful first-page availability and final completion. This is a publication candidate, not proof that reports caused a specific hang.

### 3. Reduce transcript and settings layout work

Across the capture, AppKit `layoutSubtreeIfNeeded` accounts for 7.231 main-thread CPU seconds, with overlapping `NSHostingView.layout` and sizing work. Transcript text measurement accounts for 813 ms; 578 ms occurs in the 8–14 s window. There are 17 unresponsive intervals in that window, totaling 2.825 seconds. The main thread is nearly saturated in several half-second bins around 9–13 s.

Current selection changes recreate detail and native transcript containers. Transcript updates can reload rows on source changes, then reload and force synchronous layout again as width settles. Preserve a stable container with explicit meeting-state reset, avoid duplicate reloads at intermediate widths, and retain bounded row-height caches keyed by text and effective geometry. Check editing, scroll, speaker assignment, playback, and accessibility before accepting this change. UI layout must remain on the main thread.

General Settings has broad store/health/model observations and many native controls. Its 514.6 ms stall is CPU-heavy, with nested sizing/layout stacks. Inspect which state publications invalidate the full form, isolate observation to affected rows, and stabilize control sizing. Do not conclude that `GeneralSettingsView.body` itself consumes the full 502 ms; most sampled work is framework layout beneath the surrounding update. No SwiftUI cause-and-effect instrument was captured to identify the exact initiating state change.

The low-CPU 505.6 ms stall remains in the measured timeline for completeness, but is excluded from the current optimization priorities at the user’s request.

## Capture quality and limitations

CPU, lifecycle, Core Animation context, Hangs, disk routine, and Core ML tables exported sequentially. Core ML and physical disk routine tables contain no rows. That does not prove zero filesystem work: cached reads, file metadata calls, and decoding are visible in CPU stacks. No GPU or ANE hardware activity tables are present, so accelerator use cannot be assessed. Core Animation events describe layout/display/prepare work, not screenshots, clicks, exact screen readiness, or GPU utilization.

The issue database contains `Data stream: Time Mapping`, also present in earlier captures. Unlike the unusable combined trace, this trace's CPU/event exports succeed. The issue entry alone therefore does not establish corruption. Visual opening in Instruments was not verified in this analysis. Timing precision and unmeasured profiler overhead remain limits. Hardware metadata reports a MacBook Pro with 64 GiB memory, macOS 26.6.2, Instruments 27.0 (27A266a). Exact installed source revision, cache state, library size, power/thermal state, and action sequence were not established. Source inspection uses the current working tree; correspondence with the installed binary is not guaranteed.

The source trace remains at its supplied Downloads path by the user's retention request. Private exported tables and summaries are under `/private/tmp/gday-startup-analysis-20261007/`; the generated interactive timeline is ignored under `tmp/startup-analysis/`. No real meeting content, person names, library identifiers, or source paths from user documents are copied into this report. No application code was changed.

## Verification for a future optimization

Repeat the same launch/navigation sequence on the same release build and library conditions, three times. Compare first-frame and usable-list/content times, main-thread stall count/duration, index CPU and elapsed time, and post-work settling. Preserve completed index correctness, saved edits, task recovery, and latest-selection behavior. A faster initial frame alone does not establish better interaction performance. Use a short CPU/Hangs capture first, adding a separate SwiftUI capture to identify the state changes that trigger broad layout.
