---
title: Select and browse meetings
date: 2026-10-07
status: draft
scope: macos-user-journey-performance
journey_id: meeting-navigation
---

# Select and browse meetings

## Intent and questions

I want to select a meeting and read it promptly, or browse quickly with the keyboard. Does obsolete loading stop or become harmless when selection changes? Does repeated read, decode, layout, or publication work delay the interface?

## Setup and variants

Follow the [shared procedure](README.md#shared-run-procedure). Proposed fixture: 100 synthetic meetings including 5-, 60-, and 180-minute transcripts with notes and labels. These sizes and fixtures are pending agreement. Keep detail tab and window size consistent. Separate first selection after launch from repeated selection; report cache state when known.

Start idle. Later repeat during recording or Find Voices. Vary library size separately from transcript size; avoid changing both in one comparison.

## Natural language actions

1. With the list settled, click a small, medium, then long meeting. Measure input to correct readable detail and usable controls. Record selection feedback separately: a highlight or spinner is not a completed load.
2. Repeat the same selections to observe warm behavior. Verify title, transcript, notes, and labels belong to the selection.
3. Click five different meetings about half a second apart without waiting for loads. After the last click, wait for its content. Watch whether obsolete content replaces it or the UI freezes completing old requests.
4. Focus the list, hold Down Arrow for three seconds, and release. Record repeat settings, selections received where observable, selection at release, and time until its detail is readable. Watch list scrolling and post-release settling.
5. Repeat with Up Arrow. Include a paging boundary if available. Do not mistake input dropped by automation for deliberate app coalescing.
6. Scroll the final transcript, open Notes, then return. Check controls respond and old loads do not replace content. Repeat the matched sequence three times with the same starting position and cadence.

## Measurements and profiling

Start with Time Profiler/Hangs. Add File Activity for reads, Allocations for retention, SwiftUI for publication, and native AppKit stacks for text layout. GPU/ANE is unnecessary for the idle baseline unless evidence shows unexpected model work.

Measure click-to-feedback, input-to-readable-content, post-release settling time, stalls, main-thread CPU/waits, read count/bytes, and memory recovery. Count started/completed/cancelled or superseded loads only when traces/logs expose them. Missing events are an evidence gap. Sample weights are not wall-clock load time. Compare transcript sizes and first-use/warm conditions.

## Expected experience

The list accepts input during loading, the latest selection wins, obsolete results never replace it, and work settles after navigation stops. Stale content and lost input are failures regardless of speed. Agree on absolute loading targets after measuring the baseline.

## Open decisions

Agree on representative sizes, first-use/warm load targets, keyboard cadence, and whether paging boundaries or detail-tab changes need separate journeys. Record final-content correctness alongside timing.
