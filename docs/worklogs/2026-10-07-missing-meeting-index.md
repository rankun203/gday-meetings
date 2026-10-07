---
title: Reconcile missing meetings from the disposable index
date: 2026-10-07
status: complete
scope: macos-library
---

# Reconcile missing meetings from the disposable index

## Problem

A failed cold meeting load displayed a missing-file error without requesting reconciliation. Meeting folders are authoritative; a disposable index row does not establish that a meeting exists. The load failure was also absent from app diagnostics.

## Implemented solution

Missing-file load failures request a separate background job labeled **Updating Index**. The library coordinator serializes the disk check and index update on its existing reconciliation queue. It resolves the meeting location again, checks that the library and meetings directory are available, and removes the index row only when authoritative metadata is still missing. Source files are never deleted or rewritten by this cleanup. The catalog refreshes after removal and the missing-meeting error clears. A renamed meeting, unavailable library, active document transaction, or a different missing content file does not authorize index removal.

The existing Tasks progress row presents the job. No view layout or controls changed. The supplied screenshot shows the current problem: a persistent missing-file message below a populated list. The intended behavior is to show index maintenance in Tasks and remove the obsolete list entry after reconciliation.

Library diagnostics now record load error domain/code, a private meeting identifier, successful stale-row removal, and reconciliation failures. Failure to update the index is reported separately from meeting loading.

## Reasoning

Reuse the existing reconciliation queue and background-task presentation. Treat filesystem absence as an index-maintenance trigger, not a source-document repair request. Rechecking the location avoids deleting a record for a renamed folder; unavailable roots and transactions require preserving the index until the source can be checked.

## Technical debt

None. The index remains disposable and cleanup creates no replacement source data.

## Validation

All 22 focused tests in four suites passed, including automatic cleanup after a deleted-folder load, absent metadata, preservation of audio/content, renamed folders, unavailable library directories, active document transactions, meeting selection, deferred playback, and external changes. Formatting, lint, and whitespace checks passed. The isolated `make build-macos` release build passed in 264.97 seconds, with macOS 26.0 minimum and SDK 27.0. Plist and code-signature checks passed; its source snapshot matches the working tree. Remote CI results are checked and reported separately after pushing. Existing Command Line Tools linker search-path warnings remain. The user's library has not been modified. Live task presentation and the affected startup have not been exercised in the running app.
