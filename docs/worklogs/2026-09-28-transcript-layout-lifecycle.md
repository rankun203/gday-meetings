---
title: Transcript layout lifecycle
date: 2026-09-28
status: validated
scope: swift-transcript
---

# Transcript layout lifecycle

## Problem

Returning to Transcript or changing meetings could show blank content or rows moving independently. Initial playback following started immediately after `reloadData`, before the viewport width and row heights settled. Subsequent width changes invalidated all heights using AppKit's default animation while the scroll timer retained a target from the earlier geometry. A newly selected meeting could also briefly mount the previous meeting's cached rows before its asynchronous refresh.

## Implemented solution

- Cancel following when the transcript source or width changes. Coalesce layout work, invalidate heights without implicit animation, and settle layout before positioning.
- Place a newly opened transcript immediately at its active passage, or at the top when it does not own playback. Preserve the visible row and its offset during later width changes. Continuous playback still moves the whole scroll viewport smoothly.
- Consume the shared `PlaybackProgress.snapshot`, including its seek revision, instead of subscribing to a playback action signal. Highlighting and following remain transcript-owned reactions to the central clock.
- Do not mount cached rows belonging to another meeting while the new display model is refreshed.

## Reasoning

Geometry must be final before calculating a deep scroll target. Disabling row-height animation prevents individual rows from appearing to fall into position; playback animation changes only the clip-view origin. The initial placement is immediate so opening a tab is not treated as a playback transition.

## Validation

Inspected the user's blank/deep-position screenshots and captured the existing isolated Preview transcript before editing. The 2,000-row regression passes, checking immediate deep-position placement, stability after timer delay, and resetting to the top on a different meeting even with the same generation number. In Preview, a copied 106-minute meeting was opened at 50:42 after seeking through a Summary citation. The matching 50:37 passage was highlighted; returning from Summary again preserved the populated passage. A screenshot captured the correct highlight and position. No blank viewport occurred in these checks. This verifies the regression paths, not sustained 120 Hz rendering on every device.

## Technical debt

The selected transcript still holds its row models and measured heights in memory; this change does not introduce document-level paging. The existing short playback-follow timer remains time based, not synchronized to display refresh. Neither constraint is a backward-compatibility bridge. Future work should be driven by profiling large selected transcripts and measured animation cadence rather than assuming sustained 120 Hz.

## Consolidated test follow-up

The full suite exposed a sidebar test timing assumption unrelated to transcript geometry: its fixed 400 ms settling loop can be exhausted by other main-actor tests before SwiftUI renders animation completion. The regression now waits for the latest expansion's observable completion with a bounded five-second deadline while continuing layout passes. It retains the stale-completion reversal assertions, optional strict timing check, and Reduce Motion checks. No sidebar production behavior changed.

## Main panel and sheet scrolling audit

The user reported smoother scrolling for the same long meeting in a Tags sheet than in the main Meetings panel. Both routes instantiate the same `MeetingDetailView`, `MeetingTranscriptView`, and native transcript table. The sheet adds a Done button and a fixed 800 × 650 frame. Speaker rendering and transcript subscriptions are shared; the meeting-list bounds observer is scoped to its own clip view, so transcript scrolling does not call meeting-list prefetch. A paused waveform has no display link.

Inspection found redundant work on actual scroll input: both the table and enclosing scroll view suppressed hover, and each suppression invalidated every available row and replaced a delayed work item even when hover was already disabled. The design preserves the existing layout, native whole-surface scrolling, and 150 ms quiet interval. Only the enclosing scroll view handles wheel suppression; repeated events extend one pending deadline. Visible rows redraw only when hover is disabled or re-enabled. A native regression checks that 1,000 repeated momentum updates do not repeatedly invalidate a visible row.

This removes a demonstrated per-event redraw path. It does not establish that this path alone caused the difference between windows. Parent-agent visual comparison and samples during equivalent scrolling remain necessary; no sustained 120 Hz claim is made.

All 13 focused native transcript tests passed (`/tmp/gday-transcript-scroll-tests.log`). The new regression instruments redraw sweeps without activating a test window: 1,000 repeated events add no redraw while hover is suppressed; resuming hover adds one. The initial main-panel process sample (`/tmp/gday-main-transcript-scroll.sample.txt`) captured 10,239 of 10,276 main-thread samples waiting for events and mostly accessibility queries otherwise. It missed active scrolling and cannot establish the source of the reported lag. Existing Command Line Tools linker search-path warnings remain.
