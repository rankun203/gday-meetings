---
title: Task filters and recent activity ordering
date: 2026-10-22
status: implemented
scope: macos-task-history
---

# Task filters and recent activity ordering

## Problem

A recently paused voice job remained buried in Tasks because the list sorted by creation date. The filter menu mixed execution status with one maintenance type. User screenshots provide the baseline: an old paused job is absent from the visible first page, and Search Index Maintenance appears alongside statuses.

## User intention

Make paused work easy to find. Separate the filter menu into Status and Type, list every task kind, and apply one filter at a time. The user explicitly chose this simpler interaction after an initial proposal for combined filters; that proposal is superseded. Preserve the running test app and real library.

## Implemented solution

- A native menu selects one status or one type with a single checkmark. All Tasks resets the selection. Type selections replace status selections and vice versa.
- Indexed display pages sort by the latest saved execution transition, with stable IDs breaking ties. Progress updates do not change this order. Backend recovery and execution retain creation-order pages.
- Counts and pages use matching predicates, including automatic indexing in the appropriate status. SQLite reads run away from the main actor. Batched filter revisions scope refreshes to relevant changes.
- Pausing a voice job in Tasks reveals and selects it. If Active would hide it, the screen switches to Paused. Resume, Retry, Restart, and Cancel retain and reveal the acted-on task when it still matches the filter; subsequent selection or navigation takes precedence.
- The newest page follows recent activity when its viewport is at the top. Older-history browsing retains applied page boundaries and its viewport. Incoming pages relocate overlapping IDs before trimming the bounded window. Valid off-window selections retain their details without forcing a scroll.
- Asynchronous pages validate filter, visibility, generation, and selection before publication. Task data is reconciled against live stores. Data changes schedule one follow-up refresh; notifications let in-flight reads finish. Revealing a moving target retries once, then falls back to an ordinary page. Missing or hidden external task links load the current filter.
- The disposable task index adds an activity timestamp and rebuilds from the unchanged authoritative journal.
- An opt-in synthetic preview fixture provides a day-old running voice job without starting a worker, for pause and cancellation interaction checks.

## Reasoning

The screenshots establish an ordering and discoverability problem. Sorting the shared indexed query fixes counts, filtering, and pagination together; sorting only the retained page would leave old paused jobs undiscoverable. Separate display and recovery cursors preserve scheduling behavior. A bounded page and native filter menu retain the split layout, keyboard selection, details, and actions.

Exact data-revision retries were rejected after review because continuous indexing could prevent a page from publishing. Live reconciliation with a coalesced follow-up allows progress while retaining strict filter and visibility checks. Reveal retries are bounded so a moving target cannot hold the UI indefinitely.

## Technical debt

None added. The legacy maintenance scope remains for backend callers; the presentation query separates status and type without changing their contracts. The existing visibility cache still captures loaded meeting tags when tags are excluded; its cost was noted by review but not measured or claimed as a resolved bottleneck.

## Validation and review

- Final focused automated run: **77 tests in 10 suites passed**. Coverage includes every task type, mixed managed/voice stores, index rebuilding, bidirectional paging, legacy recovery order, progress stability, stale generations, cancellation, bounded reveal retries, uninterrupted page loading, off-window selection, capped overlapping pages, visibility, timing, native list refresh, and voice failures.
- Formatting, lint, and whitespace checks passed. An earlier build was invalidated by a concurrent source signature change; subsequent frozen-source builds and tests passed.
- The first release passed in 294.08 seconds. Its isolated Task Menu Preview verified native Status/Type sections, every menu type, one checkmark, Active → Pause → Paused selection retention, and the paused task first in All Tasks. Captures are under ignored `tmp/task-filters/`. This interim release predates the final review fixes.
- Claude Code reviews used verified **claude-opus-5-5** model usage. Accepted findings covered action retention, repeated stale-load retries, notifications cancelling active loads, hidden-focus consistency, stale totals, off-window details, and moving reveal targets. The final follow-up found no remaining defects in those fixes or the selection override. Static integration review also found and fixed applied-cursor drift and loss of an overlapping task during page trimming.
- The suggestion to request additional approval for including maintenance in status filters was rejected: the accepted design separates status and type, so a status matches every task of that status. The global activity summary continues to present indexing separately.
- Remaining coverage limits: missing/hidden external focus is reviewed statically without a direct view-level automated test. Large-history paging is covered by automated tests; real-provider execution and real-library migration are not exercised by the synthetic preview.
- Final release passed in **248.69 seconds**, with macOS 26.0 minimum and SDK 27.0 verified. Ad-hoc signature verification passed. Existing Command Line Tools linker search-path warnings remain; no deprecation warning was observed.
- Final visual validation is **blocked**: Computer Use repeatedly returned `cgWindowNotFound` (-10005) for the uniquely identified validation app and Finder, including an existing Finder binding. The final preview process launched, but no window could be inspected. No permission rejection was reported. Earlier rendered/menu/pause checks remain valid for the interim build; final action-retention and cancellation behavior has automated and static-review coverage, not a completed final rendered interaction pass.

## Handoff

- Full test app: `tmp/task-filters/Gday Meetings Review Test 3.app`.
- Isolated synthetic app: `tmp/task-filters/Task Filter Validation.app`.
- Build revision: `b46a0f8e7635e3ecf30b8c7b86b1466a34fcb518-dirty`; built at `2026-10-22T01:59:49Z`.
- Full executable SHA-256: `7360d330e79d8e68b75197536bde664c7ae7319e5d8db2b576deef0595cd89fb`.
- Ignored artifacts include source manifest/diff, build/test logs, three verified Opus review results, and interim screenshots.
- Test sequence: quit other Gday Meetings copies, open Test 3, pause an older voice task and check its selection/recent position; switch between Status and Type and confirm only one is active; leave Tasks and return; check that a type such as Find Voices includes all its statuses. Final developer-owned visual checks should resume in the isolated app when Computer Use can access its window.

The running test build and real data have not been replaced. Work remains uncommitted on `master`; no push or CI run is part of this iteration. Separate settings changes committed during this work are preserved.
