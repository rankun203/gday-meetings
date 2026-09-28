---
title: Associated meeting pages
date: 2026-09-28
status: implemented
scope: swift-context-detail
---

## Problem

People and Tags detail views showed only their first 20 associated meetings, with no way to reach older meetings.

## Implemented solution

Keep the existing list and add Newer and Older controls below it, with a shown count. Each action replaces the current page with at most 20 indexed metadata rows using creation-date/ID cursors. Direction buttons disable when the index reports no further records. Run queries off the main actor and expose failures with Try Again. Opening a meeting still hydrates only that meeting. Chat remains explicitly limited to the 20 newest associated meetings.

## Reasoning

A bounded page avoids accumulating metadata for large relation sets. Cursor queries use the existing relationship index in both directions; no entire-library decoding or increasing SQL offset is needed.

## Validation

Root captured the regular Tags baseline with Research and two associated meetings before implementation. Added a 45-meeting test for both tag and person relationships, checking every page, newest-first order, backwards navigation, total count, and disabled boundary states. Final tests and visual comparison are pending.

## Technical debt

An already-open page refreshes on navigation rather than subscribing to every external relationship edit. Reopening the detail also refreshes it. Targeted relation revision notifications are a future refinement; existing underlying data remains authoritative.

The focused associated-page test passed for both tag and person filters, covering 45 records across three pages and returning to the newest page. Existing Command Line Tools linker search-path warnings remain. The root task performs the consolidated build and changed-screen validation.

The signed release Preview visual check passed: the Newer/Older footer appears below the associated list, the shown count agrees with the single fixture meeting, and both directions are disabled at the boundaries. The final full suite passed all 425 tests. Multi-page navigation is covered by the 45-record regression; the Preview screenshot uses a one-record association.
