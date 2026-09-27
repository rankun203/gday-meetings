---
title: Notes image export and archive
date: 2026-09-26
status: implemented
scope: swift-app-and-server
---

# Notes image export and archive

## Problem

Text exports and server archives preserve Markdown but omit the local images it references. Exported notes therefore cannot reconstruct their image content.

## Design before implementation

Captured and inspected the existing Export Meeting Text save panel in isolated Preview before editing, then cancelled it. It defaults to JSON and describes JSON and Markdown export, without a format picker. The installed recording and original meeting files were not touched.

Keep the native save panel and add a native format picker for JSON, Markdown, and TextBundle. JSON remains the default. The selected format determines the extension. Explain that referenced local images are included and audio is excluded. Markdown uses an adjacent `<export-name>-assets` directory and rewritten relative image paths. JSON retains canonical Markdown and includes a manifest mapping its image paths to that sidecar directory. Import copies validated manifest images into the new meeting's assets directory. TextBundle contains `info.json`, `text.markdown`, and `assets/`, following the [TextBundle specification](https://textbundle.org/spec/).

Server archives gain raster image artifacts with validated relative names, media types, byte counts, SHA-256 hashes, and base64 bytes. Existing artifact storage and canonical request hashing retain these immutable bytes without a database migration. Capabilities advertise image support; an older server archives text with an explicit image-omission warning. Preflight the complete encoded request against the existing 20 MiB limit. Authenticated artifact retrieval returns notes and image bytes with safe MIME and download headers; no external image is fetched and no SVG or HTML image route is introduced.

The local library advances to format 4 for image assets and phrase-level notes. The explicit version 3 → 4 step does not rewrite existing Markdown or assets; assets are created lazily. The original version 3 index is backed up before saving version 4. Older apps reject the newer library under the existing read-only guard. Validation uses temporary libraries; the installed app's real library has not been migrated by this work.

## Implemented solution

`MeetingExport` flushes pending notes and reconciles managed previews before using the shared notes asset resolver for originals and display copies. Markdown rewrites image tokens to a sibling directory; JSON retains markers and a relative image manifest. Existing asset folders are preserved by choosing a new numbered sidecar. Import validates containment and symlinks, copies files and normalizes managed preview references before inserting the meeting, and rolls back new files if saving fails. Renaming the JSON file does not invalidate its manifest. Legacy JSON without a manifest still imports its text and reports that images were not included.

TextBundle exports include the required metadata, Markdown, and assets, retaining another editor's custom metadata when replacing a bundle. Invalid existing metadata is rejected without replacing the bundle. The save panel uses the supported native format picker on macOS 15 and later, with a native accessory picker on macOS 14.2. TextBundle is declared as an imported package type.

`ArchiveNoteImages` creates image artifacts and checks the encoded request size before audio upload and again before submission. Immutable checkpoint snapshots retain image bytes for retries, and their hashes include both image references and content. Older servers receive text/audio with a persistent checkpoint flag and an explicit image-omission warning. The server validates and stores images in existing artifact JSON, advertises its capability, and provides authenticated artifact downloads with content verification and safe response headers.

## Reasoning

A sidecar keeps JSON compatible with existing meeting decoders without embedding large binary values in every export. TextBundle provides a single portable package. Inline archive image artifacts fit the existing immutable JSON snapshot and authorization model.

## Technical debt

The archive's existing 20 MiB request ceiling also bounds encoded image content. Base64 increases request size. Larger notes remain locally exportable but require a future authenticated binary attachment transport to archive all images; validation must report the limit without silently dropping content.

## Validation

Server type checking and all 39 tests passed against disposable local databases, including original-byte image download, unauthorized access, traversal, canonical base64, MIME/digest/size mismatches, immutable retry conflicts, tampered stored content, and the complete 20 MiB request limit. Existing test fixture warnings report missing email configuration and no forwarded client IP.

The latest coordinated Swift suite passed 308 tests in 63 suites (8.244 seconds), including export/import/hash, missing-preview regeneration, version 4 migration, and hosted editor regressions. Format and lint passed. Development packaging and signature verification also passed. Existing Command Line Tools linker search-path warnings remain.

A separately identified temporary Preview app verified the native export picker and filename changes, JSON as the default, and successful JSON, Markdown, and TextBundle saves. Inspected the generated image files, relative references, JSON manifest, and TextBundle metadata. The installed app and user-owned Preview were untouched. The macOS 14.2 fallback and rendering in an external Markdown editor were not exercised; automatic review denied the read-only app inventory used to find an external viewer, without a stated reason. No real recordings have been uploaded.

Image editor UI checks found two TextKit crashes, with their bundles and reports preserved separately. After the user approved the exact Fresh validation app launch, the previous long-paste/final-image/scroll sequence passed with correct image placement. A packaging mistake copied the obsolete pre-rename output: Fresh contained the 01:02 crash-fix candidate (binary UUID `886B803A-A33F-3823-89FA-7CA1EBE0B3A5`), not the latest continuity changes. That check validates the earlier crash and placement fixes only. The latest source passed automated checks and the 38.54-second production build at `.build/macos/Gday Meetings.app`; its continuity, toolbar, and invisible resize corner have not received native visual acceptance. Subsequent user activity stopped further UI interaction. The remaining native image, Read mode, layout, and live-highlight checks are explicitly limited in their worklogs; passing automated tests does not imply those checks ran. The installed app and active user fixture were not replaced.
