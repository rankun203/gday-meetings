---
title: Transcript navigation and layout responsiveness
date: 2026-10-05
status: implemented
scope: swift-transcript-performance
---

## Problem

Meeting navigation and sidebar resizing could delay interaction. The reported screenshot also showed unusually large gaps between transcript rows. Native cell reuse alone does not bound all work: changing meetings reads history and builds display rows, while width changes invalidate row geometry.

## Evidence and reasoning

Profiled the isolated `40e64af-sidebar-review` release Preview with `GdaySyntheticLongTranscript`, a 10,000-row synthetic Latin transcript, in dark appearance. A 45-second Time Profiler recording covered Down/Up navigation between the long transcript and an empty transcript, sidebar expansion/collapse, and scrolling. The trace and exported stacks are under ignored `tmp/responsiveness-ui-2026-10-05/transcript-synthetic-baseline.*`. Screenshot inspection showed compact rows before and after these operations; the reported large gaps were not reproduced.

The recording sampled 2,960 ms of main-thread CPU. Inclusive samples attributed 183 ms to height calculation, 162 ms to layout settling, 127 ms to history loading (123 ms in checkpoint reading), and 13 ms to display-row construction. These totals overlap and are not individual interaction latency. Accessibility inspection itself contributed 1,233 ms, so this is diagnostic evidence, not a clean benchmark.

[Apple's row-height documentation](https://developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:heightofrow:)) explains that the table caches delegate heights and a full reload invalidates that cache. The app uses [native cell reuse](https://developer.apple.com/documentation/appkit/nstableview/makeview(withidentifier:owner:)), but reload and text measurement still cost CPU. The existing short-line cache avoids repeated shaping when a complete line fits; wrapped or multiline text still needs width-dependent measurements. [WebKit's performance guidance](https://webkit.org/blog/8970/how-web-content-can-affect-power-usage/) likewise identifies main-thread layout and painting costs. Moving the transcript to CSS would not by itself remove those costs.

## Implemented solution

`TranscriptHistoryReader` resolves the meeting folder and reads the live checkpoint and saved revisions in a detached task. `MeetingTranscriptView` refreshes saved text immediately and awaits the history snapshot. The task identity includes the library, meeting, transcript source, and speaker-label source. Publication requires the latest admitted request, an unchanged identity, and an uncancelled task. Same-meeting refreshes retain existing history while loading; changing meeting or library clears it. Restore actions await the same reader.

No renderer rewrite or row-height heuristic was introduced.

A synthetic native-table regression now reproduces stale row geometry. The fixture uses the production table configuration, real delegate and cells, and a hidden native window. With table bounds unchanged, widening the transcript column from 310 to 570 points left a wrapped Latin row at 298 points and a CJK row at 266 points; fresh current-width measurements require 90 points for each. Replacing a long meeting with a shorter transcript during the same intermediate column-width sequence reproduces the mismatch. Both tests fail before the fix (five geometry assertions). This establishes a reproducible mechanism; it does not prove that the original screenshot came from that exact sequence.

The concrete design preserves the existing row controls and layout. The current `40e64af-async-review` Preview transcript was captured and inspected before the renderer edit; its three synthetic short rows had natural spacing. Row-height invalidation now tracks the exact column width used by the delegate rather than floored table bounds. Both the table layout observer and the settling cache use that width. A content update also invalidates the settled-width marker when its current column width differs: otherwise a source replacement can cache narrow-column heights and later return to the old wide width without triggering another reload. Unchanged-width partial and live updates keep their existing reuse path. The existing coalesced layout scheduling, edit protection, and scroll anchor remain.

## Technical debt

The existing full reload on each settled width remains. It preserves established editing and scrolling behavior but may measure many wrapped rows during resizing. Follow-up: use a clean synthetic profile to determine whether narrower invalidation can reduce measured resize cost while preserving the new native geometry regressions. No additional rendering shortcut was introduced.

## Validation

The deterministic async-reader tests passed in the consolidated persistence run. The initial combined persistence release passed in 162.70 seconds before the geometry fix.

The two new native geometry regressions failed before the renderer change. Updating only the width key fixed column resizing but left source replacement failing; conditional invalidation at intermediate widths fixed the second case. The final targeted run passed all 46 tests across seven suites in 0.782 seconds without warnings. It covers native row geometry, wrapped Latin/CJK, live-row reuse, editing, keyboard selection, scrolling, playback visibility, and deep-position/source replacement. These assertions read actual native row rectangles and do not require Instruments.

The first after-build visual verification attempt was blocked by computer-use tooling on October 6. Selecting the original isolated Preview returned `cgWindowNotFound`; selecting the debug Preview stalled for 127.7 seconds despite a 20-second tool timeout and returned no accessibility tree or screenshot before interruption. That attempt produced no wrapping, Down/Up navigation, sidebar-resize, or Labelings popover result, and further attempts were stopped at that point. The automated 46-test native geometry and interaction result remains valid; it does not substitute for a final screenshot. The original real-meeting gap screenshot has not been reproduced directly, and no clean post-change frame-pacing benchmark has been recorded.

The final combined release, including the geometry correction, passed in 176.24 seconds without compiler warnings or errors. Preview revision `40e64af-people-persistence-review` passed linked-platform, metadata, and strict signature checks. Formatting, lint, and diff checks passed. The installed app was not replaced.

The full precommit suite exposed a separate fixture race in live-transcript issue recovery: the synthetic provider delivery waited for two storage checkpoints inside the controller's real five-second provider-finalization deadline. Under shared main-thread load, that deadline correctly rejected the later phrase. The fixture now delivers each phrase in a short completed session and awaits storage recovery separately, preserving the failure/recovery assertions without extending the production deadline. Validation of this fixture change is pending the coordinated rerun.

A later bounded October 6 retry succeeded with release Preview `40e64af-people-persistence-review`. Captured screenshots show compact synthetic rows with the sidebar collapsed, natural two-line wrapping after widening the meeting-list column and expanding the sidebar, and correct rows after Down to the empty meeting and Up back to the conversation. No oversized stale gaps appeared. The Labelings popover displayed its saved synthetic analysis instead of remaining in Loading History. This closes the short-fixture visual check; the automated geometry tests remain the evidence for long Latin/CJK fixtures, and physical two-finger gestures and clean frame-pacing measurements remain unverified.
