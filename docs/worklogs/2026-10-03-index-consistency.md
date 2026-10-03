---
title: Atomic library index updates and file event reconciliation
date: 2026-10-03
status: active
scope: swift-library-index
---

## Problem

An incremental index update could replace meeting metadata and remove search and relationship rows before a transcript read failed. Database errors could also leave a partially updated meeting. Multiple file events for one meeting repeatedly read and indexed its transcript. Events naming only the library or meetings directory did not remove stale rows for deleted folders.

## Implemented solution

- `LibraryIndex` uses nested SQLite savepoints for updates, removals, and duplicate-folder quarantine. Transcript reads happen before row changes. A failed operation rolls back its database changes and discards its speculative folder lookup.
- Reconciliation normalizes path syntax without resolving filesystem aliases and indexes each affected folder once per batch. File URL standardization shortened existing `/private` roots but left deleted event paths unchanged; preserving the watcher’s physical spelling keeps deletion events in scope. Only the folder itself, metadata, notes, summary, transcript, and transcript checkpoint trigger indexing. Audio, content sidecars, event journals, and nested attachments do not contribute index fields. Different folders with the same meeting ID remain separate candidates so duplicate protection still applies.
- A library-root or meetings-root event requests coordinator discovery and the existing bounded-memory rebuild to discover additions and remove stale rows, with normal progress reporting. Direct index callers retain the same ancestor-event rebuild fallback. Per-meeting events retain incremental indexing.

## Reasoning

Savepoints work both independently and within rebuild transactions, preserving the previous committed rows after file or database failures. Filtering uses the canonical file format: list fields and relationships come from metadata, and full-text content comes from notes, summary, and the transcript projection. Directory-level events contain too little information to identify deleted meetings, so they require a scan.

## Validation

A physical-root regression covers a deleted folder reported with the `/private` path used by FSEvents. Coordinator regression coverage injects both ancestor event forms into the worker queue, starting from a completed index and cursor, then verifies discovery of an arbitrarily named folder, stale-row removal, and a rebuild notification. Regression tests also cover malformed transcripts, a database failure after search and relationship deletion, failed removal and quarantine, successful retry, one update per event batch, irrelevant-file filtering, checkpoint events, ancestor-only deletion events, and discovery during reconciliation. Existing paging, duplicate-folder, symlink, and dated-folder tests are included in focused validation. All 37 focused tests in five suites passed sequentially using Xcode outside the tool sandbox, including real file-event audio adoption and subsequent folder removal (log: `/private/tmp/gday-index-tests.log`). A full-suite run exposed a deterministic deletion failure caused by filesystem-dependent `/private` normalization; the lexical normalization fix and dedicated regression resolved it. An attempted sandboxed monitor run could not complete initial discovery and is not counted as validation. Swift formatting and diff whitespace checks passed. The successful focused Xcode run reported no compiler or deprecation warnings. Release build, full tests, lint, and CI results are coordinated with the related migration change.

## Technical debt

None added. Directory-level events require a full rebuild; ordinary file events remain bounded to affected meetings. Existing library-wide scaling limits remain documented in the file library implementation worklog.

## Integrated validation

The final sequential suite passed 730 tests in 129 suites. The initial parallel run also encountered the repository's existing asynchronous deadline failures; sequential execution resolved those failures without changing production deadlines. Swift lint and diff whitespace checks passed. `make build-macos` passed with Xcode, including release compilation, property-list validation, and signature verification. The final test and release logs contained no compiler or deprecation warnings. CI is checked after pushing.
