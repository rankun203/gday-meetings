---
title: Publish library changes only when persisted data changes
date: 2026-10-08
status: complete
scope: macos-library-reconciliation
---

## Problem

File notifications caused library revisions, directory revisions, and meeting-page refreshes even when recording writes changed no authoritative documents or a document matched the persisted state. These publications could make SwiftUI update broad parts of the recording interface.

## Implemented solution

- Keep import discovery active, then classify authoritative meeting documents separately from audio and provider artifacts. Audio-only events in existing meeting folders no longer notify index, directory, or document consumers.
- Compare decoded meeting metadata, folder location, relations, and search passages against the shared SQLite index before updating derived records. Compare search passages by their indexed locations rather than scanning all meetings. A repeated event or unchanged rebuild preserves the derived revision; rebuilding still repairs missing relations.
- Compare directory entities, person-tag memberships, and associated meeting counts before publishing a directory revision. Skip unchanged error assignments.
- Read external documents under the existing saved-state and mutation guards. Refresh visible meeting entries without loading-state publications, replace only changed entries and IDs, and invalidate prefetch only when the visible catalog changes.
- Preserve recovery scans, new-folder adoption, external document edits, deletion, and final recording metadata updates.

## Reasoning

The successfully persisted documents and shared index provide the reconciliation baseline. No event is assumed to be an echo of an app write, and no separate watcher cache decides which document edits to ignore. Relevant events still cause a read; equal data causes no model publication. Filtering recording bytes avoids unnecessary document reads while leaving monitoring available for other meetings.

## Technical debt

None. Existing recovery scans still publish their building and progress state even when their final projection is unchanged. This is deliberate status reporting for a scan, rather than a document or directory revision.

## Validation

Regression coverage checks unchanged saved documents produce zero store publications, recording audio produces no consumer callbacks, changed notes and final duration remain visible, semantic no-op index and directory updates preserve revisions, and rebuilding repairs missing relations. Existing persistence, external reload, search, directory paging, and prefetch suites are included in validation.

The combined regression run passed 55 tests across seven suites; the audio import suite passed six additional tests. All six external-library tests passed again after replacing the initialization wait with a deterministic revision check. Strict Swift formatting passes for every changed Swift file, and `git diff --check` passes. Repository-wide `make lint-macos` reports existing formatting errors in `LiveTranscriptView.swift`, `VoiceLibraryStore.swift`, and `Models.swift`; these files are unchanged.

The final reviewed source passed `make build-macos` in an isolated snapshot at `/tmp/gday-reconcile-release` (macOS 26.0 minimum, SDK 27.0, bundle and code-signature validation passed). The build did not replace the running development bundle. SwiftPM reports missing Command Line Tools linker search directories; these are toolchain search-path warnings, not deprecated APIs. No UI layout or controls changed, and no new CPU trace has been captured.
