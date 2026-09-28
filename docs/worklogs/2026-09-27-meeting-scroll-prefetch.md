---
title: Meeting list prefetch and stable scrolling
date: 2026-09-27
status: complete
scope: swift-meeting-list
---

# Meeting list prefetch and stable scrolling

## Problem

The 100,000-meeting app stopped at the bottom after a few hundred rows. The current screenshot and accessibility snapshot showed 202 list items, a permanent “Loading newer meetings…” row, and a scrollbar near the bottom while the visible meeting window had moved. Top and bottom SwiftUI appearance handlers could fight each other when the 200-row window rotated.

## Design and implemented solution

Replace synthetic loading rows with a native reusable table preserving the existing title, date, summary, status icons, selection, context menu, and double-click playback. Observe the actual viewport instead of cell or sentinel appearance. Start background cursor reads at least 40 rows before an edge; increase lookahead with scrolling speed, up to 240 rows. Each database request remains a 20-record page; one operation may read up to ten pages.

The metadata window targets 800 rows. Rotation retains the first visible meeting ID and its exact pixel offset, including fractional row offsets. The viewport and 40 neighboring rows are protected; one in-flight batch may temporarily increase the cache to 1,000 rows. No loading row remains at either edge. New meetings can still be revealed at the top, while ordinary data refreshes retain the current position.

Search/reset cancels prior work and clears loading state. Results must match both the cursor ID and creation time before application, preventing stale appends after a date edit. Background queries determine whether another record exists rather than treating a full page as proof of more data.

## Validation

New tests preserve the same visible meeting and pixel offset through forward and backward native window rotation. A 1,600-record fixture exercises early prefetch, bounded forward/reverse traversal, and cancellation during a search reset. The combined focused run passed 16 tests in 3 suites. The full serial run passed 380 tests in 78 suites (`/tmp/gday-prefetch-final-tests.log`), including the existing native top-spacing test.

On September 28, the parent agent validated the updated Weekly full app with 1,000 meetings. Repeated fast scroll calls of 35 pages traversed meeting 001000 through 000001. Additional scrolling at the actual end stayed on 000001. Reverse scrolling passed 000528, 000801, and 000901 and returned to 001000 without any loading rows. Selecting 001000 opened its full 1,132-segment transcript. Screenshots at the bottom and at the selected top meeting were inspected. This verifies end detection, forward/reverse paging, and selection in the full app; perceived trackpad smoothness still needs the user’s assessment.

## Technical debt

None added to the paging flow. Full-text matching latency and entity/task scale limits remain documented in the storage worklog. No frame-rate guarantee is made from automated tests; fast trackpad scrolling needs the user’s assessment on their display.
