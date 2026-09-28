---
title: File library and disposable index
date: 2026-09-27
status: complete
scope: swift-storage
---

# File library and disposable index

## Problem

The compact JSON catalog still required whole-catalog reads and writes. Loaded meeting payloads accumulated as the user browsed. Per-meeting UUID folders also crowded the data root.

## Implemented solution

- Removed runtime legacy library migrations, old-folder copying, global-to-provider prompt migration, and the serialized aggregate library model. Development data conversion is handled by the parent’s temporary script.
- Authoritative meeting documents live under `meetings/<base36-id>/`: metadata, content, transcript, summary, and notes are separate files. New IDs encode monotonic nanoseconds; internal UUID references remain strongly typed.
- `index.db` stores derived metadata, relationships, and full-text search. Cursor queries load 20 metadata records without loading transcripts. The native list targets 800 metadata rows, allowing one in-flight batch while protecting the viewport; clean payload caching retains 24 meetings, with active work pinned.
- Writes journal only affected documents, preserve independent durable notes, and update the disposable index after committing files. Startup restores interrupted file transactions.
- Rebuild runs through a separate SQLite connection with WAL readers retaining the committed view. Malformed documents retain their previous indexed row and report errors; other records continue. Corrupt database files are quarantined and recreated.
- Indexed row IDs keep full-text replacement bounded instead of scanning every search document on each update. Cursor paging uses stored negative timestamps and covering relationship order indexes: SQL query plans show ordered range seeks without a temporary sort.
- Flat-folder rebuilds inspect only immediate meeting folders, recycle prepared statements, and decode only transcript text for search. Per-iteration autorelease pools include enumeration and metadata lookup. An initially empty index publishes 500-record batches; existing-index rebuilds retain atomic replacement visibility. A persisted completeness marker ensures interrupted initial builds restart.
- People and tag relationship cleanup processes 20 meetings per batch and removes the entity only after cleanup completes.

## Validation

The focused index and native transcript run passed 12 tests in 2 suites (`/tmp/gday-index-seek-tests-final.log`). Paging tests inspect the actual SQLite query plans in both directions and verify no temporary sort for meeting and tag cursor queries (people use the same relationship query). A separate-reader test observes the first 500 committed records during initial indexing and the unchanged snapshot during a subsequent rebuild. Only the existing Command Line Tools linker search-path warnings remained.

Focused tests cover metadata-only pagination, full-text search beyond the first page, relationship queries, identity round trips, minimal audio folders, corrupt index replacement, and malformed-record isolation. The parent worklog records final integrated test and full-app benchmark results.

## Technical debt

- People and tags currently retain their editable entity arrays. Their disk representation is independent files, but very large entity populations still need indexed directory paging and targeted hydration.
- Task replay retains current task rows in memory; a very large task history needs indexed history queries.
- Full-text filtered pages materialize matching IDs and walk the ordered index until enough hits are found. Search latency still depends on the number and distribution of matches; dedicated search result cursors remain a follow-up.
- Relationship deletion batches memory but remains synchronous; extremely large relation sets should use a resumable background task.
- File transactions provide crash recovery and conflict detection, but are not a cross-process locking protocol. Agents should use atomic document replacement; coordinated multi-document concurrent edits need an explicit transaction protocol.

## Layout correction

The user rejected hash bucket folders after inspecting Finder. All meetings now live directly under meetings/<base36-id>/. The two benchmark datasets and staged development migration are converted to the same flat layout before final measurements.

## Integrated validation and development migration

- Before the subsequent native transcript-table and index-query refinements, all 366 tests in 76 suites passed with serial execution. The full app build and Swift lint passed. Command Line Tools still emits missing Developer framework/library search-path warnings; no new deprecated API warning was observed.
- After the user confirmed the regular app was closed, a temporary script converted its 36 meetings and 1,458 transcript segments into the flat layout. SHA-256 checks matched all 65 audio files (163,156,157 bytes). The original data remains at `/Users/kun/.local/share/com.gdaymeetings.macos-backup-20260927-231432`; the converted library is at `/Users/kun/.local/share/com.gdaymeetings.macos`. The installed old app must not be launched against the new format; the final handoff uses the newly built app.
- Separate full-app fixtures contain 1,000 copies of `search vs ai overview weekly` (1,132 segments each) and 100,000 copies of source `55D3791A-2D68-42EF-B0B2-8B672E032E37` (14 segments each). IDs and internal references are distinct. Media uses independent APFS clones where available, with copy fallback; mutable JSON is independently written. Providers and automatic processing are disabled in these fixture libraries.
- Fixture roots are `.build/benchmarks/weekly-1000` and `.build/benchmarks/review-100000`. They contain flat meeting folders. The benchmark bundle has a separate application identifier and runs the normal app with `GDAY_SWIFT_DATA_DIR`; it is not UI Preview.
- On an Apple M1 Max with 64 GiB RAM, the preliminary 1,000-meeting run settled near 141 MiB RSS and 0% sampled idle CPU. Sampling began after launch, so this does not establish its cold-start time or peak memory. Final measurements follow below.

## Measured index refinement

The first 100,000-record full-app run finished its initial index in approximately 475 seconds (process start to the first read-only query observing all rows). Sampled peak RSS was 512 MiB. The warm restart settled near 144 MiB and 0–0.1% idle CPU. Native UI inspection confirmed 100,000 records in Data and paging beyond the first 20. This baseline exposed the all-or-nothing first-build delay and unnecessary recursive file enumeration; it is not the final performance result.

After flat-folder enumeration, narrower transcript decoding, statement reuse, and initial batch publication, the 1,000-record full-app run published its first 500 records at 4.33 seconds and all 1,000 at 6.42 seconds. Sampled peak RSS was 172 MiB, settling near 112 MiB with 0% idle CPU. These times measure committed index availability, not display-frame timing. No filesystem-cache purge was performed, and development validation continued on the same machine. Final measurements and viewport validation follow below.

The integrated native-transcript/index build passed 375 tests in 77 suites, the release build, and lint. User testing then exposed meeting-list boundary stalls during window trimming. The native list with anticipatory background paging subsequently passed the validation below.


## Final integrated results

On September 28, the final release passed all 380 tests in 78 suites, the release build, and Swift lint. Only the existing Command Line Tools missing linker search-directory warnings remain. The full 1,000-meeting app was scrolled from meeting 1,000 through meeting 1 and back, crossing cache-window rotations without a stuck loading indicator. Selecting the long meeting opened its transcript. Preview interaction checks verified editing, speaker reassignment, playback, and delayed hover without accumulated highlights. User assessment of trackpad feel remains pending; sustained 120 Hz was not measured.

The final 100,000-meeting full-app run published the first 500 records at 35.54 seconds and all records at 526.41 seconds (8 minutes 46 seconds). Across 1,162 samples over 600 seconds, peak RSS was 143.64 MiB and peak sampled CPU was 78.9%; the final sample showed 116.69 MiB RSS and 0% CPU. The first-build memory peak improved over the earlier 512 MiB observation, while total indexing took longer than the earlier approximately 475-second run. Filesystem caches were not purged and other validation ran concurrently, so these runs do not isolate the cause of the time difference. Index availability is not a first-frame measurement. A million-record library was not tested.

Final measurement artifacts: `/tmp/gday-review100000-final-cold-samples.jsonl` and `/tmp/gday-review100000-final-cold-result.log`. Both isolated full-app benchmark windows remain available for user scrolling checks. Root monitoring was also verified in a separate full app: audio-folder import, external metadata/person/tag changes, rebuild, and selected-meeting removal all updated the UI. Development data is migrated with its original backup retained; launch the newly built app from `apps/client-macos-swift/.build/macos/Gday Meetings.app`, not the unchanged older installed bundle.

## Pre-commit identity validation

Source review found that incremental index reconciliation did not enforce the folder/metadata ID match already required by rebuild. It now rejects mismatched metadata before changing the index. Entity loading also validates canonical UUID filenames and unique IDs, so copying or renaming a people/tag file cannot create duplicate in-memory identities that later trap dictionary construction. Both error paths retain the original files.

Regression tests cover a copied entity document and a changed meeting metadata ID, checking preserved bytes and no ghost index entry. All 12 focused tests in LibraryFormatTests and MeetingPagingTests passed (/tmp/gday-storage-identity-tests.log). Existing Command Line Tools linker search-path warnings remain.
