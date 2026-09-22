---
date: 2026-09-22
title: Native CMS-managed recording files
status: validating
---

## Problem

Audio Files exposed a metadata-only create form. Users had to enter storage details and could create records with no actual file.

## Implemented solution

Converted Audio Files into Payload's native upload collection with persistent DATA_DIR/audio storage, file picker/drop zone, generated metadata and native deletion. Desktop raw uploads spool to disk and pass the temporary file to the same Payload lifecycle. Filename generation and metadata are server-owned; existing files cannot be replaced under active task references. Native URL imports and duplication are disabled. SQLite/Postgres migrations backfill native upload metadata without moving recordings or changing signed download URLs. Removed the redundant custom deletion handler. Release 0.3.3 includes the follow-up 500 MB cap and compressed-format preference.

## Reasoning

One CMS file lifecycle serves browser and desktop uploads. Payload handles file validation, authenticated downloads and deletion; per-file signed URLs remain available to RunPod. Temporary files avoid loading entire recordings into memory. Strict immutable filenames protect existing task inputs.

## Technical debt

Existing storageKey/size/contentType columns duplicate native filename/filesize/mimeType and are retained for the current signed-URL/task contract. Hooks derive them rather than accepting user values. A future schema cleanup can switch server lookups to native fields and remove redundant columns after migrating dependent API queries. Existing deployment storage remains local persistent disk; no new remote-storage adapter is introduced.

## Notes

28 SQLite tests pass, including file ownership, immutable metadata, deletion, and upgrade preservation. Seven platform tests pass against disposable PostgreSQL, including migration down/up with an existing file. TypeScript and production build pass. Browser check completed first-admin setup, selected a synthetic WAV, saved it, and confirmed generated filename, 60-byte size, audio/wav type and CMS file URL. Added one central 500,000,000-byte ceiling, configurable downward only; both upload paths return 413 above their limit and clean partial files. The UI recommends Opus/M4A/MP3 while retaining WAV. Boundary and rejection tests pass. No user deployment data touched. The 0.3.2 publication was superseded while building by the requested 500 MB limit. Publication verification pending for 0.3.3.
