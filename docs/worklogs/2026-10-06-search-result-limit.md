---
title: Keep search results capped at 100
date: 2026-10-06
updated: 2026-10-07
status: implemented-with-visual-validation-limit
scope: macos-search
---

# Keep search results capped at 100

## Problem

Semantic search already requested up to 100 content results, while Text search used an independently paged flow. Following the rendering measurements, the selected behavior is a fixed maximum of 100 results with no General setting.

## Implemented solution

`LibrarySearchSession` uses the shared 100-result maximum. `SearchCoordinator` caps every published snapshot after semantic scoring or reciprocal-rank fusion. Multiple providers or an over-returning provider cannot exceed that maximum. Explicit smaller coordinator requests, including zero, retain their meaning. People matches remain independent.

The app's Text mode now uses the same coordinated result-limit boundary. It preserves its prior passage order, query expression, and excluded-tag filtering, including separate hits from the same meeting. It no longer loads further pages beyond 100. Legacy fusion continues to use its existing ranked, meeting-deduplicated candidates and retains a pool of 100 candidates per provider before applying a smaller display limit. No new Text scoring formula is introduced.

Provider and index APIs remain configurable for candidate retrieval, legacy paging, and benchmarks. Semantic search still scores every eligible window and applies the speaker bonus before selecting its best results. General controls and the persisted settings schema are unchanged.

## Reasoning and design evidence

The coordinator is the shared boundary for user-facing results. The final request retains 100; it does not assume fewer rendered rows improve latency. Result-row layout, playback, opening, and keyboard controls remain intact.

The existing isolated preview's search page and General screen were captured and inspected. No General UI change remains. The intended search presentation is the existing page with at most 100 content rows, while People matches remain separate.

## Validation

Regression coverage spans four modes and generic request limits 0, 1, 5, 20, 50, 100, and 1000, including over-returning providers. A 150-passage Text fixture checks the 100-result cap, unchanged passage identity/order, and tag exclusions. A semantic fixture checks that a passage below the first 100 content matches enters the results only after its confirmed-speaker bonus. A fusion fixture checks that a shared candidate ranked 21st by both providers can become the top displayed result for a smaller request limit.

Formatting, lint, and diff whitespace checks passed. The focused release run passed 29 tests in four suites in 3.157 seconds, including 28 coordinator limit cases. An initial Text fixture failure came from omitted synthetic transcript end timestamps; correcting the fixture and asserting its source-page count resolved it without a production-code change.

The final isolated `make build-macos` release build passed in 194.73 seconds, including packaging and signature verification. The installable app is retained at `tmp/search-fixed-100-2026-10-07/Gday Meetings.app`, with `tests.log` and `release.log` beside it. The build reported the existing Command Line Tools linker warnings for missing `/Library/Developer/CommandLineTools/Developer/usr/lib` and `/Library/Developer/CommandLineTools/Developer/Library/Frameworks` search paths; the linked target remained macOS 26.0 with SDK 27.0. No speed improvement is claimed for this change.

Visual validation of this build is incomplete. Computer-use launch stalled without returning a window. Resetting computer use restored inventory, and a bounded Launch Services launch succeeded, but attaching to that isolated app stalled again despite an explicit 10-second tool timeout. Both stalled calls were interrupted; no changed-build screenshot or open/back interaction check passed. The preview contained only its two base synthetic meetings; no extra transcript fixture was added. Its exact process was terminated and verified exited, then its synthetic library, disposable preview bundle, and isolated build cache were removed. Existing user apps and recordings were left running. The 150-passage automated test establishes the result cap and preserved Text passage order, but does not replace the missing visual check.

## Technical debt

None. The legacy Text paging API remains available to existing callers, while the app's bounded results page uses the shared coordinator.

## Publication

The user requested committing and pushing the completed work to `master`.
The final app code is covered by the signed release build and focused tests
above. Pre-commit review also checks the benchmark aggregates, documentation,
and ignored private inputs. The single-task rebuild design remains a proposal;
this release does not claim to fix the reported rebuild interaction problems.
