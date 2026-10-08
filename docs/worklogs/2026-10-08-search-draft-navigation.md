---
title: Preserve search results while editing the query
date: 2026-10-08
status: implemented
scope: macos-search
---

# Preserve search results while editing the query

## Problem

Clearing the toolbar search field returned to Meetings and removed keyboard focus. The field contains a draft, so deleting its contents should not dismiss the submitted search.

## Implemented solution

Removed the empty-draft navigation change from `LibraryView`. Clearing or replacing the draft retains the current Search Results page and submitted query. Return submits a nonempty replacement; an empty submission remains a no-op. Sidebar navigation still changes the page explicitly.

## Reasoning

The existing draft and search session already have separate state. Removing the navigation side effect preserves that separation without adding state or changing controls, layout, or labels.

## Technical debt

None.

## Notes

- Before editing, captured and inspected the existing production search UI in isolated Preview with synthetic fixtures, light appearance, silent playback, and the `pagination-recovery-verified` banner. Bundle: `apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`.
- Reproduced the bug with the synthetic query `Alex`: the Search Results failure page returned to Meetings when Command-A and Delete cleared the field. Focus also moved away from the field. The provider model was unavailable; no model download or real recording was started.
- Design: retain the Search Results content and toolbar geometry while editing, including an empty draft. Preserve the native field's focus and editing behavior.
- The parent completed the rebuilt release check in `/tmp/Gday Search Log Preview.app`, with the `search-log-verified` banner, grouped synthetic fixtures, System appearance, and silent playback. After a successful search returned seven matches, Command-A and Delete cleared the draft while all matches remained visible and the insertion cursor stayed in the field. Captured and inspected that state; the toolbar and result layout were unchanged.
- An empty Return retained the submitted empty-result page. Entering a nonempty replacement submitted a new search. Explicit navigation to a meeting and Back to Search Results still worked. The final native clear-button check was interrupted by user activity; the Preview was left open. Other appearance and viewport combinations were not retested.
- The shared isolated release build and all 39 search tests passed. Changed-file formatting and diff checks passed. Repository-wide lint later encountered unrelated concurrent edits. No implementation-mirroring test was added for the removed state assignment. See the search-evaluation-log worklog for build warnings and shared validation details.
