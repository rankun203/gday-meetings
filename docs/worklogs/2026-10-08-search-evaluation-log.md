---
title: Search evaluation log
date: 2026-10-08
status: implemented
scope: swift-search
---

## Problem

Search returned timing metadata and results without retaining a durable evaluation history. Retrieval candidates and result interactions could not be joined for later evaluation.

## Implemented solution

- Append versioned JSON events to `providers/<provider UUID>/search-log.jsonl` in the data folder. A serial background queue and file lock preserve whole-event ordering across writers. The app drains queued writes on normal quit.
- Record submitted queries, preparation failures, provider requests, tag exclusions, resolved people, model identity and asset-manifest digest, app revision and build time, algorithm settings, completion, cancellation, and failures.
- Record each semantic retrieval round with ANN rank and distance, speaker-union membership, source revision and fingerprint, freshness rejection, and FP32 score components. Preserve the full reranked candidate order and the hydrated final results. Record monotonic stage durations and UTC event times.
- Record result snapshots accepted by the search session and link interactions to the exact snapshot, request, and submission. Store the result position, meeting-group position, and match position. Distinguish mouse row activation, keyboard activation, and control actions. Play, navigate, and match selection each produce one event; automatic playback following open does not add another click.
- Store text excerpts and source/audio references, without audio bytes or embedding vectors. Text retrieval has no separate reranker; its provider snapshot is its final retrieval order.

## Reasoning

A shared event schema makes provider execution and presentation independently inspectable. Source revisions and model settings allow comparison after a model or feature change. Clicks remain implicit relevance signals; they are not explicit relevance judgments and do not label unclicked results irrelevant.

The existing search field and controls need no visual changes for logging. Initial Preview inspection showed the toolbar search field; submitting a synthetic query opened provider settings because the model was missing. Result-screen comparison needs a prepared synthetic fixture. The separate clear-search navigation fix is tracked by its own worklog.

## Technical debt

None. Logging is best-effort when storage is unavailable; failures are reported to the app's unified `SearchLog` log category. Readers must skip malformed lines left by an interrupted write. The next append preserves that line and starts a new line. An abrupt process termination can lose queued events. No automatic rotation or deletion is performed, as requested.

## Validation

- All 39 tests in seven search suites passed in the isolated checkout: append concurrency and escaped queries, torn-tail recovery, symlink rejection, display/click attribution, failure and cancellation events, complete candidate coverage before top-100 truncation, and existing search/session/preparation regressions.
- The new append tests exposed an existing-directory error after the first event. Directory creation now accepts `EEXIST` and then checks that the path is a directory rather than a symlink; the complete test selection passed after this correction.
- The isolated `make build-macos` release build passed, including packaging, code signing, and minimum-platform validation (macOS 26.0, SDK 27.0).
- Changed-file formatting, shell syntax, and diff checks passed. The final repository-wide lint encountered concurrent, unrelated edits in `VoiceLibraryView.swift` and `MeetingVoiceReview.swift`; those files were left untouched.
- Verified the signed release in `/tmp/Gday Search Log Preview.app`, bundle ID `com.gdaymeetings.macos.search-log-preview`, banner `search-log-verified`, grouped synthetic fixtures, System appearance, and silent playback. Copied only the installed Granite model into its temporary synthetic library; no real meeting data was copied. A cold search returned zero results before indexing completed; the next search returned seven matches. Both executions and their displayed snapshots were appended.
- Exercised mouse open, passage selection, result playback/open control, explicit navigation, and keyboard open. Parsed the JSONL and confirmed that each controlled interaction produced exactly one event and referenced the correct displayed snapshot and request. The log also included source revisions, all seven candidates, ranking order, model manifest digest, and packaged app revision/build time.
- Captured and inspected the populated results screen after clearing the field: all seven matches remained, with the insertion cursor in the empty field. Explicit navigation still opened the chosen meeting, and Back to Search Results restored the search. A later native clear-button check was interrupted by user activity; no more UI actions were taken and the isolated Preview was left open. Other appearances and viewport sizes were not retested because this change does not alter layout or styling.
- Command Line Tools emitted linker warnings for missing `Developer/Library/Frameworks` and `Developer/usr/lib` search paths. No deprecation warning appeared in the test build. These toolchain paths are not supplied by the changed code; no dependency or API migration is required for this task.
- The running development app and its library are left in place. Only synthetic content is used for evaluation fixtures. Reconstructing source content beyond saved result excerpts requires retaining the referenced library files; the log is not a media backup.
