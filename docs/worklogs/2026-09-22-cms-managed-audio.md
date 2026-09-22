---
date: 2026-09-22
title: Native CMS-managed recording files
status: complete
---

## Problem

Audio Files exposed a metadata-only create form. Users had to enter storage details and could create records with no actual file.

## Implemented solution

Converted Audio Files into Payload's native upload collection with persistent DATA_DIR/audio storage, file picker/drop zone, generated metadata and native deletion. Desktop raw uploads spool to disk and pass the temporary file to the same Payload lifecycle. Filename generation and metadata are server-owned; existing files cannot be replaced under active task references. Native URL imports and duplication are disabled. SQLite/Postgres migrations backfill native upload metadata without moving recordings or changing signed download URLs. Removed the redundant custom deletion handler. Release 0.3.4 includes the follow-up 500 MB cap and compressed-format preference.

## Reasoning

One CMS file lifecycle serves browser and desktop uploads. Payload handles file validation, authenticated downloads and deletion; per-file signed URLs remain available to RunPod. Temporary files avoid loading entire recordings into memory. Strict immutable filenames protect existing task inputs.

## Technical debt

Existing storageKey/size/contentType columns duplicate native filename/filesize/mimeType and are retained for the current signed-URL/task contract. Hooks derive them rather than accepting user values. A future schema cleanup can switch server lookups to native fields and remove redundant columns after migrating dependent API queries. Existing deployment storage remains local persistent disk; no new remote-storage adapter is introduced.

## Notes

28 SQLite tests pass, including file ownership, immutable metadata, deletion, and upgrade preservation. Seven platform tests pass against disposable PostgreSQL, including migration down/up with an existing file. TypeScript and production build pass. Browser check completed first-admin setup, selected a synthetic WAV, saved it, and confirmed generated filename, 60-byte size, audio/wav type and CMS file URL. Added one central 500,000,000-byte ceiling, configurable downward only; both upload paths return 413 above their limit and clean partial files. The UI recommends Opus/M4A/MP3 while retaining WAV. Boundary and rejection tests pass. No user deployment data touched. The 0.3.2 publication was superseded while building by the requested 500 MB limit. Published 0.3.3 smoke found native multipart staging attempted /app/tmp, unwritable by the non-root container user. Fixed tempFileDir to OS temporary storage and added a native-architecture image upload/download/delete check before publishing version/latest tags. Local non-root 0.3.4 Docker build passed multipart upload, authenticated byte-exact download, anonymous denial and physical file deletion. Releasing correction as 0.3.4; publication verified.

User requested only AMD64 and ARM64 entries in the image index. Disabled BuildKit SBOM/provenance attestations, which produce unknown/unknown entries. Verify the published index has exactly the two runnable platforms.

Release v0.3.4 (f494e6f) published successfully in Actions run 35691282723. Both native AMD64/ARM64 container smoke tests passed. Anonymous registry inspection confirms 0.3.4 and latest share digest sha256:93d44155914d4a2e1c38d5f8a60e946d00ec300af6896f075e23f772682bcc87 and contain exactly linux/amd64 and linux/arm64, with no unknown entries. Disposable test containers and local browser test server were stopped.
