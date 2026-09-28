---
title: Data monitoring and Settings
date: 2026-09-27
status: complete
scope: swift-app
---

## Problem

The library needed file change discovery and a visible index maintenance screen.

## Implemented solution

A single recursive FSEvents stream watches the data root, coalesces paths, and excludes index/cache/staging files. A serial background coordinator reconciles changed paths and records the acknowledged event cursor. Missing cursors and dropped history request a scan. Audio-only drops receive minimal metadata and a canonical compact-ID folder without starting provider tasks. Existing malformed metadata is left intact.

Settings gains Data: selectable folder path and Show in Finder; index size and Rebuild Index on one row; processed-count progress and incomplete-count text; Meetings, People, Tags, and Tasks counts.

## Reasoning

Captured and inspected the existing native Settings window before UI edits: three toolbar tabs and a grouped form. The new tab follows that layout with native controls and no new material effects. Unknown rebuild totals use an indeterminate progress indicator.

## Technical debt

Copy completion is inferred from two size/modification-time observations plus a settling interval; an atomic folder move remains the dependable handoff for agents. Counts for people, tags, and tasks currently reflect loaded store records. External settings/provider changes are observed but not yet reloaded into unsaved settings forms; reopening the app loads those files. Reconciliation preserves unsaved meeting edits and requires Resume for externally changed active tasks, rather than submitting provider work from a file edit.

## Validation progress

Added tests for filtering disposable paths, audio-only normalization, malformed metadata preservation, live filesystem discovery with audio duration, and external task edits requiring Resume. Native Settings baseline and the changed Data tab were captured and inspected. Audio duration uses the existing bounded container readers on the background worker. Scanner event queues and settling samples are capped at 4,096 paths. Reviewed [Apple’s FSEvents flags](https://developer.apple.com/documentation/coreservices/file_system_events/1455361-fseventstreameventflags) for dropped-event recovery.

## Initial indexing feedback

The 100,000-meeting full-app benchmark exposed a misleading empty state: Meetings displayed **No Meetings** and a recording prompt while Settings correctly showed **53,000 meetings processed**. Captured both screens without stopping the running benchmark. The intended state is a centered indeterminate spinner, **Building Index**, and a processed count in the empty list; the unselected detail area says **Meetings will appear when indexing finishes.** Normal empty-library/search states return when building ends. A locally observed helper updates progress without invalidating the complete library view. Index size now refreshes at the existing 500-record progress cadence, including the database, WAL, and shared-memory file. The active benchmark was preserved while the loading-state change was implemented.

## Progressive initial indexing

Initial empty-index rebuilds now report committed batch counts from the index worker. The monitor loads the first page when the first batch becomes visible, then checks whether either paging cursor has more records without replacing the current rows or selection on every progress update. This re-enables infinite scrolling when a user reaches the end of a partial index and another batch commits. Completion refreshes the current catalog window instead of returning to page one. Existing-index rebuilds keep their previous committed count until the atomic commit.

Folder discovery has a separate reading phase and checked-folder count, so the initial scan does not look stalled at zero indexed meetings. The empty-detail text now says **Meetings will appear as they are indexed.** Added a regression test for first-batch visibility, preserved rows, and reopening both paging directions after a later batch. Build and full-app verification are coordinated by the parent agent; no benchmark process was interrupted for these edits.

## Full-app watcher smoke finding

The isolated full app initially missed an audio-only drop under `/private/tmp` after its startup scan. A standalone FSEvents probe reproduced the cause: Foundation URL standardization shortened the watched path to `/tmp`, while callback paths used `/private/tmp`. The unmatched-path fallback also admitted the app's own cursor writes, causing a notification loop. Watch roots now use POSIX `realpath` without Foundation shortening, and callbacks accept only the known canonical root/prefix. Deleted paths do not need to exist to match that prefix. The corrected probe reports the synthetic changed file and no cursor-write loop. The live-drop regression now waits until startup scanning finishes before creating the drop, so it tests actual event delivery. The corrected full-app validation is recorded below.

## Corrected full-app validation

The rebuilt, signed full app used an isolated data root at `/private/tmp/gday-file-watch-smoke-d30e35dc-4a0a-4e90-83a8-52f2f53a7675`. After startup scanning completed, an audio-only folder named `Folder drop smoke` was added. The running app normalized it to `meetings/dlq56wxfx9mo`, created metadata, measured the one-second WAV, and indexed it without a restart or provider task. An external metadata title edit and person/tag file additions also reached the disposable index; relationship queries returned one person and one tag. The shared focused suite passed all 16 tests, including live event delivery after startup and removal of a loaded meeting after its folder moves out of `meetings/`.

Native full-app checks confirmed the externally renamed meeting, one-second duration, and attached **Watcher Tag**. The Data tab showed the isolated folder and counts of one Meeting, one Person, one Tag, and zero Tasks. **Rebuild Index** completed without an error and preserved those counts; displayed index size changed from 371 KB to 408 KB. The one-record rebuild completed before the screenshot, so this check did not capture intermediate progress. Moving the selected synthetic meeting into excluded `staging/` preserved its files and removed the indexed row without restarting the app; the selected-detail screen check is recorded below.

The final native screenshot confirmed that the removed meeting disappeared from both the list and the selected detail view. The screen returned to **No Meetings** with no stale title or editable transcript, and the task summary remained **No active tasks**. The isolated smoke app was then quit; benchmark and user apps were left running. Full-app folder import, external title/relationship updates, Data counts/rebuild, and selected-meeting removal are verified. Initial-progress feedback was inspected separately in the running 100,000-meeting benchmark; the tiny smoke fixture cannot establish large-library performance.
