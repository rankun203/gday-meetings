---
title: Transcript playback and speaker presentation
date: 2026-09-28
status: validating
scope: swift-app-ui
---

# Transcript playback and speaker presentation

## Problem

The transcript painted the last table selection, not the current playback position. Seeking on the waveform and advancing playback left the old row highlighted. Speaker badges cached appearance-dependent colors before cells joined their window, leaving inconsistent fills after reuse or appearance changes. The user asked for compact colored speaker chips and playback following similar to the Rust transcript and Music lyrics.

## Implemented solution

The native coordinator observes the playback meeting, clock, waveform scrub position, and explicit seek completion. A cached timeline sorted by segment start resolves the latest passage at or before the current time through binary search. Only the previously active and newly active visible row presentation changes. A subtle accent tint and accent timestamp mark playback; delayed pointer hover remains neutral. Pausing retains the current position. Playing another meeting clears the displayed transcript's playback tint. Text colors change without changing font metrics or row heights.

Compact speaker pills fit the name inside the existing speaker column. Assigned people use their person ID as the color key; other labels use their speaker ID or source label. Deterministic collision avoidance gives the first eight distinct identities separate colors within the meeting. The palette repeats beyond eight identities. Unassigned labels have a dotted outline; automatic person matches count as assigned. All colors resolve in the current drawing appearance. The label truncates only when it exceeds the column, preserving full name accessibility text.

Playback follows the active passage toward 30% of the transcript viewport when it is more than 40 points away. The 250 ms ease-out scroll starts only when the active passage changes. Actual wheel, momentum, or scrollbar interaction cancels it immediately and suspends following for four seconds. Editing or an open person picker also suspends following. Waveform scrubbing updates the highlight without repeated scrolling; committing a seek recenters once. Reduce Motion disables scrolling and background transition animations. Ordinary active-row background transitions last 180 ms.

## Reasoning

The supplied screenshots establish the baseline: a row at 00:02 remains highlighted at 00:18, while waveform seeking does not update the transcript. Playback must determine this state independently of selection. Rust's `webui/transcript.mjs` provides the compact chip, active timestamp, 30% viewport target, and four-second manual-scroll pause reference. The native implementation detects actual user input instead of treating its own programmatic scrolling as manual input. Direct native updates avoid rebuilding SwiftUI rows or measuring text on every clock sample. Name and person resolution use dictionaries built once for each transcript refresh.

## Validation

All 19 focused transcript and playback tests passed; Swift lint and `git diff --check` passed. Tests cover advancement, reverse seek, exact segment starts, no selected meeting, another meeting, pre-transcript time, actual playback-clock and scrub subscriptions, compact assigned and unassigned chips, palette stability and collision avoidance, and native follow-scroll cancellation and suppression. In the isolated 10,000-segment Preview, a waveform click to 00:53 highlighted the 00:48 passage and moved it to about 30% of the viewport. Advancing playback to 01:00 moved the highlight and viewport to the 01:00 passage. Light-mode inspection confirmed compact colored pills and dotted unassigned outlines. The first light palette was too faint, so chip foreground and outline now resolve darker colors in light appearance and lighter colors in dark appearance; all eight palette colors pass a 4.5:1 foreground contrast check over the modeled chip/window surface in both appearances. Eleven native transcript tests pass after that refinement; the preceding combined native/playback run passed 19 tests. Final appearance inspection follows. The existing Command Line Tools warnings for missing Developer library and framework search paths remain.

## Technical debt

No storage or compatibility debt added. The finite eight-color palette repeats for larger speaker sets. Collision avoidance is deterministic within each meeting; a colliding identity may use a neighboring color in meetings with different speaker sets. Names and the dotted assignment outline remain available independently of color. Existing selected-transcript memory and height-measurement limits remain unchanged. The short follow animation uses a common-run-loop timer; it is not a measured or guaranteed 120 Hz display-synchronized animation. Profiling on actual hardware remains necessary for a sustained ProMotion claim.
