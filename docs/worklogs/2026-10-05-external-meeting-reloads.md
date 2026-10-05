---
title: Read external meeting changes without blocking interaction
date: 2026-10-05
status: implemented
scope: macos-persistence
---

# Read external meeting changes without blocking interaction

## Problem

Folder-monitor events discarded affected meeting identities. Every meeting event could decode all loaded clean meetings on the main actor, delaying playback and other input.

## Implemented solution

External change batches retain affected meeting IDs, including dated/base36 folder names. Ancestor and recovery events still cover all loaded clean meetings. Full meeting reads, deletion checks, and transaction-marker checks run on a utility worker. Catalog failures remain independent of meeting recovery.

Publication checks a library generation, per-meeting local revision, newer external events, the original saved/current values, pending notes, and recording/job ownership. Local edit-and-revert sequences change the revision even when equality returns to the original value. Removed or evicted meetings cannot be resurrected. Revision maps retain only loaded IDs. Persistence commands can invalidate reads at admission through `invalidateExternalMeetingReloads(ids:)`.

## Reasoning

External files remain authoritative only when local state stayed clean throughout the read. Moving decoding alone would allow delayed results to overwrite newer edits; explicit revisions and lifecycle guards define the publication boundary. Worker reads never write canonical content. An active document transaction retries rather than treating temporarily missing files as deletion.

## Technical debt

No new schema or compatibility bridge introduced. Related task-journal and canonical-write migration is recorded in its own worklogs. Some independent indexed paging queries remain synchronous; the save-triggered visible-page refresh now runs on a worker.

## Validation

ExternalMeetingReloadTests and ExternalLibraryChangesTests passed, covering slow storage, local edit-and-revert, save admission, notes edits, library generation changes, deletion, scoped paths, malformed files, and transaction markers. The integrated monitor test now explicitly loads a cold meeting after the model getter became memory-only; its rerun passed. These suites passed again in the consolidated 217-test run. The combined `40e64af-async-review` release passed in 162.70 seconds without compiler warnings and passed platform/signature checks. No UI wording or layout changed.
