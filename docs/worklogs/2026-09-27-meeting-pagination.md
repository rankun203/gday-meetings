---
title: Folder-backed meeting pagination
date: 2026-09-27
status: implemented
scope: swift-app-storage-and-meetings-ui
---

## Problem

The Meetings list and store loaded every transcript and notes file before showing the library. Limiting visible rows alone would not reduce that work. The user requested pages of 20 ordered newest first, backed by meeting folders.

## Design before implementation

Used the supplied Meetings screenshots as the baseline. Keep the existing native rows, sidebar, search, selection, recording, and playback controls. Load the next 20 meetings when the list reaches its loading row. Append older rows without scrolling the selection. Search all persisted meeting content, including meetings outside the loaded pages, then page matching results. Programmatic Open Meeting loads that meeting without forcing earlier pages into view.

## Implemented solution

Library format 5 stores compact list metadata in `library.json` and full meeting payloads in each UUID folder's `meeting.json`. Notes remain in `notes.md`. Startup retains the metadata index and reads only the newest 20 payloads and their notes. Payloads remain cached once opened. The index can be rebuilt from folder payloads when absent. Existing library migration retains its original backup and writes folder payloads before publishing the new format.

`MeetingPaging.swift` handles stable creation-date ordering with ID ties, page hydration, targeted access, and cancellable background search. `LibraryView.swift` uses paged metadata and a loading/retry footer. Creating or importing meetings refreshes visible rows, while loading an older page does not trigger the creation scroll behavior.

The store merges changes into the complete metadata catalog and leaves unloaded payloads untouched. Tag counts, association lists, and privacy destinations use compact metadata. Targeted export, assignment, archive, recording-import, transcript, and task actions hydrate their meeting before accessing content; context chat hydrates the matching set. Live transcript recovery also runs when an older meeting is opened.

Changed payloads and the previous catalog are recorded in `.meeting-save.json` before replacement. On save failure they are restored before returning failure. Startup restores an interrupted save before loading the library; removing the journal commits the save. This keeps task completion receipts and catalog changes together. Journal paths are limited to `library.json` and UUID meeting payloads. Notes retain their separate existing save and conflict behavior.

## Reasoning

A compact catalog allows ordering and association counts without reading transcript bodies. Keeping loaded payloads cached preserves active editors, recording state, playback, and job references. Folder files remain usable to rebuild the list. A bounded rollback journal covers changed payloads and the catalog rather than copying the entire library on every save.

## Validation

Added tests with 45 meeting folders for initial 20-payload and 20-notes hydration, subsequent pages, search beyond the first page, targeted opening, stable ordering, untouched unloaded files, rollback of payloads and task receipts when catalog saving fails, interrupted-save recovery, and catalog rebuilding. All five initial paging tests passed in the integrated 346-test run. That run exposed a missing hydration-time speaker association normalization; restored the existing startup behavior when reading a folder payload. Added a sixth regression for person/tag deletion reaching an unloaded meeting without changing its transcript or visible page. Updated existing format/notes assertions for folder storage. The integrated run still had three task-queue expectation failures being handled by the task owner; the follow-up run and native screenshot checks remain with the parent task.

Final validation: all 365 tests across 73 suites passed, including the hydration and off-page relationship regressions. Preview build, formatting, lint, and diff checks passed. Existing Command Line Tools linker-search-path warnings remain. Post-change native screenshots and scroll/search interaction checks could not be completed because the computer-use service returned `cgWindowNotFound` after relaunch. The synthetic 45-meeting fixture is available for follow-up; production data and the installed app were not changed.

## Technical debt

The metadata catalog remains proportional to the number of meetings, and full-text search scans persisted content without a dedicated search index. This keeps the storage model small while making ordinary browsing lazy. Search work is cancellable and runs off the main actor. If library size makes scans slow, add an incremental search index keyed by payload and notes revisions.

Loaded payloads stay cached for the app session. This avoids evicting data referenced by editors, playback, and background jobs. A bounded cache would need explicit pins for those consumers before safely releasing old pages.
