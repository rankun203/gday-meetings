---
title: Recover pagination after refresh and cancellation
date: 2026-10-07
status: completed
scope: swift-pagination
---

# Problem

Refreshing the meeting catalog cancelled read-ahead without clearing its loading flag. The cancelled completion correctly rejected its old generation, but no remaining request could clear the flag. Scrolling then stopped after the first page and the end count stayed hidden. People and Tags had the same gap when configuration cancelled a request and its replacement had no index.

Tasks retained an old detail selection when a filter returned no rows. Voice error rows used current failures while pagination controls used a separately cached count. Resolving every failure's context before displaying a page also added unnecessary main-thread work.

# Implemented solution

Meeting read-ahead cancellation invalidates the request and clears its loading state together. Completion cleanup checks its generation before changing state. A save refresh owns loading until it finishes, rejects obsolete results and errors, and resumes read-ahead for the current viewport without requiring another scroll event. People and Tags clear cancelled loading state before attempting replacement requests.

Tasks reconcile selection with each returned page, including empty pages. Scope changes hide old detail while preserving the selected ID if it belongs to the new page. Voice failure rows and controls derive from one current page, with at most 20 context resolutions. The Tasks session owns cancellation and generation-checked cleanup. An explicit task reveal takes priority over ordinary refreshes, which coalesce until it finishes. The layout remains unchanged.

# Reasoning

Cancellation transfers ownership of loading state synchronously. Generation checks prevent a late completion from clearing a newer request's state. A single reset entry point prevents callers from forgetting half of that operation. Existing cursor-based bounded windows remain in place.

# Validation

- Synthetic regression tests reproduced stuck Meetings and directory loading on the previous implementation.
- Added traversal coverage after cancellation, unavailable-index recovery for People and Tags, and cancellation followed by a replacement associated-meeting refresh.
- All 35 meeting, directory, and associated-meeting paging tests passed in 11.573 seconds. The synthetic 366-entry regression reaches the end after cancellation without hydrating meeting content. Both People and Tags recover from an unavailable index.
- All 50 focused Tasks tests passed, including eight new session and failure-page regressions. After the final selection-preservation correction, the full default suite passed 1,074 tests across 184 suites in 113.136 seconds. Formatting, lint, and whitespace checks passed.
- Independent review found and verified the additional task-reveal versus refresh race. No remaining blocker was found in the reviewed fixes. Claude Code Opus review remains unavailable because of its previously confirmed monthly quota limit.
- The production repair passed release validation in 180.10 seconds with strict signing verification and no compiler warnings. Native Preview reached the 200-task footer, scrolled back across the retained task window, and reached the 47-meeting footer. Voice errors paged forward and backward as 20, 20, and 1, with the correct boundary buttons disabled. A selected voice task survived a matching scope change.
- Two fixture-only repairs let synthetic Tasks and paged Meetings run together: seed tasks before meeting-cache eviction and rely on snapshot restoration to preserve Preview tasks once. When unrelated speaker-association edits arrived, final validation moved to `tmp/pagination-validation`, containing the committed baseline and only the pagination changes. Its 19 targeted tests passed in 0.612 seconds; its release passed in 217.23 seconds. The build targets macOS 26 using SDK 27. The running installed app was not replaced.
- Cloning an existing build cache produced stale-path warnings during the initial isolated rebuild. Rebuilt outputs resolved those cache warnings; the subsequent release pass completed in 0.80 seconds without warnings. No source or deprecated-API warnings were reported.
- Final isolated Preview showed four distinct alerts consistently in its badge, Review button, and filter. Dismiss All Alerts cleared attention while Failed retained four tasks. Switching from a selected failed task to the empty Needs Attention filter showed no old detail and no stuck loading state. Screenshots were captured in Light appearance; Dark was covered by the earlier Tasks work but was not revalidated for this repair. Growth and shrink during processing remain automated-test coverage; the visual fixture is static.
- The macOS 26 and 27 release workflow is checked after pushing the repair. Claude review remains limited by the account quota described above.

# Technical debt

None introduced. The existing pagers have different data sources and window contracts; this change preserves those components and repairs their cancellation and presentation invariants instead of introducing a second shared pagination layer.
