---
title: Read and edit transcripts during layout work
date: 2026-10-07
status: draft
scope: macos-user-journey-performance
journey_id: transcript-layout
---

# Read and edit transcripts during layout work

## Intent and questions

I want to move between meetings, resize the window, and edit or play a transcript without layout blocking the interface. Does reopening a meeting reuse measured heights while creating a fresh table? Do estimates settle without moving the text I am reading? Does rapid navigation leave a bounded amount of obsolete work?

## Setup and variants

Follow the [shared procedure](README.md#shared-run-procedure). Use an isolated synthetic library with short and long transcripts, multiline text, CJK text, and lines close to a wrapping boundary. Record row counts, text lengths, window width, display scale, typography, and build revision. Keep these conditions fixed for cold and warm comparisons.

Start with an empty in-memory layout cache. Reopen the same meeting at the same width for the warm comparison. A new app launch or a different library window is a separate cache lifetime. Run navigation, resizing, and editing as separate short captures so their costs can be attributed. Measure live appends in a separate run with synthetic input and the provider configuration recorded.

## Natural language actions

1. Open the long meeting and read the first visible rows while measurements arrive. Check text wrapping, speaker labels, and row spacing. Scroll to the middle and note the top visible row and its offset within the viewport. Wait for corrections and check that this reading position stays stable.
2. Open another meeting, then return to the long meeting at the same width. Compare measurement counts and cache hits with the cold run. Confirm selection, editing, and playback highlighting belong to the current meeting.
3. Hold Down Arrow in the meeting list for three seconds, release, and wait for the final selection. Repeat with Up Arrow. Confirm that obsolete measurement results never change the current table, pending work stays bounded, and work settles after navigation stops.
4. Slowly resize the window across a line's wrapping boundary, then resize quickly several times. Return to the original width. Check that text does not clip or overlap, cached heights match the rendered width, and reading position remains anchored. Observe whether width variants and pending inputs stay within their limits.
5. Edit one line to add several wrapped lines, save, and then shorten it. Check that the edited row is remeasured, other unchanged rows reuse heights, and the editor and selection remain usable. Remove a row where the app supports that action and check that obsolete work cannot restore it.
6. Start playback, seek, and pause. Check that highlight updates do not cause new text measurements or transcript reconstruction. Rename a speaker and verify that any height invalidation follows the actual row geometry.
7. In the separate live-input run, append new transcript lines and revise the provisional tail while reading or editing. Check that only affected rows require new heights and that the reading position follows the existing live-following policy. Stop input and confirm pending work settles.
8. Close the tested meeting page. Delete a disposable synthetic meeting and check that its cache entries and requests are removed. Exercise memory-pressure cleanup through the test harness if available; missing heights must be safely measured again.

## Measurements and profiling

Capture Time Profiler and Hangs for main-thread CPU and unresponsive intervals. Use Allocations in a separate matched run to inspect retained cache and pending-input memory. GPU and ANE tracks are unnecessary for text-layout isolation; live transcription resource use belongs to the recording journey.

Record cache hits and misses, text measurement count, completed and cancelled work, pending request count and retained input bytes, estimated cache bytes, width variants, table reloads, height publications, and rows corrected. Compare cold and warm navigation. The 16 MB cache budget is an estimated accounting limit, not a claim about measured Swift allocations. Record actual retained memory separately and note profiler overhead.

## Expected experience

The latest meeting selection wins. Cached heights return immediately, and uncached rows can appear with estimates while workers measure them. Corrections preserve the top visible row ID and pixel offset. Text wrapping matches the rendered font, padding, and effective width. Editing, labels, saved content, and playback state remain correct.

Warm navigation reduces repeated measurement. Rapid navigation and resizing keep cache storage and pending inputs bounded. Playback, selection, and color changes retain valid heights. Faster timing does not excuse clipped text, stale content, lost edits, or scrolling jumps. Absolute timing targets remain pending a matched baseline.

## Open decisions

Agree on representative long-transcript sizes and acceptable scroll-anchor tolerance after measurement. Record which actions were operated in Preview, which used the full app, and which were verified only by automated tests. Do not infer real recording performance from a synthetic append test.
