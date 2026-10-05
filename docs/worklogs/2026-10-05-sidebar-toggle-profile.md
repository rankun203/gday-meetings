---
title: Installed app sidebar responsiveness profile
date: 2026-10-05
status: analyzed
scope: macos-installed-app-instruments
---

# Installed app sidebar responsiveness profile

## Problem

The installed app's sidebar transition felt slow and appeared to move linearly. The user toggled the sidebar during an Instruments capture. This report distinguishes measured main-thread work from assumptions about animation timing or storage delays.

## Capture and privacy

- Time Profiler attached to the installed `/Applications/Gday Meetings.app` without restarting it. No Preview, build, or UI polling ran during the capture.
- Recording: October 5, 2026, 22:29:13–22:30:24 Australia/Melbourne; duration 71.034 seconds.
- Installed executable SHA-256, independently rechecked: `576c16300cedca06fd6040ac93111d7f988b8a5f812d00bbfc6b4d5dd754872a`.
- This is the installed binary, not the later working-tree build. Stack names map to the existing implementation, but source line references below are navigation aids rather than proof of an exact build revision.
- Raw trace and XML exports remain in ignored `tmp/responsiveness-ui-2026-10-05/`. Analysis ran locally with `xctrace export` and Python. No trace or meeting content was sent to Claude or another external service. This report contains only aggregate timing and source symbols.
- User clicks were not timestamped. The trace includes a meeting-list click, so not every expensive interval can be assigned to a sidebar toggle.

## Results

The main thread spent most sampled time in AppKit and SwiftUI layout and rendering. Repeated transcript-table layout is the largest identifiable application-specific contribution. This capture does not show a database-bound sidebar transition.

| Metric | Observation |
| --- | ---: |
| All process samples | 8,800 |
| Main-thread samples | 8,193 |
| Main-thread sample weight | 8,193 ms |
| Samples containing a layout-related symbol | 5,303 ms, 64.7% of main-thread sample weight |
| Samples containing SQLite, managed-task journal, or library-index symbols | 0 |
| Main-run-loop active spans over 16.7 ms | 111 |
| Main-run-loop active spans over 33.3 ms | 39 |
| Main-run-loop active spans over 100 ms | 1 |
| Longest active span | 209.754 ms |
| Exported hang-risk rows | 0 |

Samples carry 1 ms weights. Inclusive figures count a symbol once per sample even if it recurs in that stack; nested rows below overlap and must not be added. The layout category matches `layout`/`Layout` and `sizeThatFits`/`SizeThatFits` in any frame. These are sampled CPU estimates, not exact method durations or rendered-frame counts.

### Largest relevant inclusive stacks

| Stack or method | Main-thread sample weight |
| --- | ---: |
| `CA::Transaction::commit()` | 5,534 ms |
| `NSView.layoutSubtreeIfNeeded` | 4,799 ms |
| `NSWindow` constraint-based `layoutIfNeeded` | 4,081 ms |
| `ViewGraphRootValueUpdater.render` | 2,897 ms |
| `NSHostingView.layout` | 2,759 ms |
| `AG::Graph::UpdateStack::update` | 2,564 ms |
| `NativeTranscriptView.Coordinator.settleLayout` | 839 ms |
| Transcript table `heightOfRow` delegate | 305 ms |
| `TranscriptHeightCache.measure` | 300 ms |
| `TranscriptNativeTable.layout` | 259 ms |
| Transcript cell creation | 93 ms |

`settleLayout` represents 10.2% of main-thread sample weight. Reducing it is justified, but cannot by itself account for all framework layout cost. Self samples are spread across runtime and framework work: `objc_msgSend` 447 ms, an unresolved deduplicated symbol 247 ms, `mach_msg2_trap` 153 ms, and AttributeGraph update 104 ms. Application-binary self samples total only 20 ms; expensive application entry points mostly call framework work rather than consume CPU in their own instructions.

### Run-loop timing

The run-loop export contains explicit `waiting_for_events` intervals. Their union was removed from the analysis: active spans are the gaps between the end of one recorded wait and the start of the next. Long one-second idle iterations therefore do not count as one-second hangs. These spans are wall time and may include scheduling delays or waits outside the run-loop wait markers.

The longest span starts 33.502 seconds into the recording and lasts 209.754 ms. It contains 209 main-thread samples, chiefly view updates and transaction commit/layout. A meeting-list `mouseDown`, transcript `loadHistory`, and a small folder-resolution stack also appear. It is not safe to label this a pure sidebar-toggle interval.

Other examples start at 24.927 seconds (74.058 ms), 31.235 seconds (88.511 ms), and 36.010 seconds (87.751 ms). Their samples are predominantly AppKit layout and SwiftUI view-graph rendering. These are long enough to consume several nominal 60 Hz frame budgets, but Time Profiler does not establish how many frames were actually missed.

## Source mapping and causal candidates

The pre-change `NativeTranscriptView.swift` implementation has a direct path consistent with the samples:

1. `TranscriptNativeTable.layout()` detects each changed integer width and schedules a main-queue callback.
2. `Coordinator.widthChanged()` schedules `settleLayout()` on the next main-queue turn. Cancelling an outstanding item only coalesces changes that arrive before that turn.
3. `settleLayout()` calls `table.reloadData()` and `table.layoutSubtreeIfNeeded()` whenever the settled width differs.
4. The height cache stores only the latest width per row. New widths trigger fresh text bounding-rectangle measurements; toggling back to a prior width has no retained entry.

Before the optimization, these entry points were at `UI/NativeTranscriptView.swift:442`, `:455`, `:658`, `:674`, and `:769` under `apps/client-macos-swift/Sources/GdayMeetings/`. The symbols were observed in the installed trace. The explanation that repeated resize steps amplify their work is a source-backed causal candidate; the trace has no app signposts to count exact reloads per click.

SwiftUI/AppKit layout outside this table is also substantial. The transcript change should be evaluated as a bounded reduction, not a complete responsiveness repair. No sampled canonical save, managed-task journal, or SQLite stack explains this recording. The separate static persistence audit remains valid for other actions, but is not evidence that storage caused these sidebar hitches.

## Safe improvement and validation plan

- Preserve the production `NavigationSplitView` sidebar transition. The custom `.default` animation helper belongs to optional test controls; changing it would not change the user's native toolbar action. This trace does not measure the system timing curve.
- Coalesce width-only transcript reflow instead of rebuilding the entire table at each intermediate width. Keep content updates, active text editing, explicit navigation, and live-follow behavior correct. Final row heights and the scroll anchor must match the final width.
- Consider a bounded cache of recently used widths for row heights, with text and speaker changes invalidating entries. Do not move AppKit layout onto a background thread or retain unbounded width variants.
- Use a synthetic long transcript to compare repeated native sidebar toggles before and after. Record table reload counts, text measurements, and main-loop active spans. Programmatic visibility tests cover state changes but do not exactly reproduce the native toolbar action.
- Check visible wrapping, selection, scroll position, editor continuity, live following, window resizing, rapid reversal of sidebar motion, and Reduce Motion. The final width must settle after the animation ends even if a queued update was cancelled.

## Implemented solution and validation limits

This sub-task captured no new app state and changed no application code. It exported and analyzed the existing capture, shared results with the transcript-layout implementation agent, and produced this sanitized report. The coordinated implementation and its final release validation are recorded separately. No before/after speedup is claimed here.

Time Profiler had `record-waiting-threads=0` and no context-switch sampling. Absence of storage samples does not prove all waits were absent. Empty hang-risk output does not prove smooth animation. Click latency, compositor frame delivery, exact easing, and the earlier summary freeze remain outside what this capture establishes.

## Technical debt

No new application debt was introduced by analysis. Existing repeated table reloads and single-width height caching are the concrete follow-up target. Keep the native animation and address measured layout work before introducing custom timing or animation suppression, which could hide symptoms without reducing work.
