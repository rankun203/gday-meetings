---
title: Date prefixes for new meeting folders
date: 2026-10-01
status: validated
scope: swift-meeting-storage
---

# Problem

Meeting folders showed only a base36 identifier. New folders should show the meeting date without changing meeting identities or renaming existing folders.

# Implemented solution

- Added central folder naming and lookup in `MeetingFolderLocation.swift`. New names use `YYYYMMDD_<base36-id>`, with the meeting's `createdAt` date interpreted in the current time zone using the Gregorian calendar.
- Existing plain-ID and date-prefixed folders remain in place. Editing a meeting date or changing time zones does not rename a saved folder.
- Recording and imports reserve their folder before writing audio or attachments. Audio imports retain the same creation date through file copying and metadata creation; archive and Rust-library imports retain the source meeting date and their existing ID-allocation behavior.
- Discovery, index rebuilding, and incremental reconciliation recognize both name formats. Audio, notes, export, and Trash continue using the central resolver.
- The disposable index stores ID-to-folder-name mappings in `meeting_folders`. Removal and rebuild pruning remove obsolete mappings. A bounded cache serves repeated lookups; cold lookups reuse the existing index connection and prepared statements.
- Rebuild counts folder identities before publishing metadata. Duplicate IDs are excluded from the meeting list and marked with an empty path in the existing disposable path table. Incremental reconciliation rejects conflicting copies before replacing indexed metadata or cached paths. Reads, writes, and notes report the duplicate error; removing the extra folder and reconciling or rebuilding restores the remaining meeting. Source folders are never changed by this check.
- Cached, indexed, and incrementally reconciled paths reject symbolic links at both the `meetings` directory and meeting-folder boundary. Storage and creation operations propagate a specific access error before file writes or transaction snapshots.
- The index registry keeps a pruned list of weak references per root. It selects the most recent live index and falls back when a transient index closes; registration does not retain connections.

# Reasoning

The date describes the folder, not the meeting identity. Keeping the actual path in the disposable index preserves direct lookup even when the stored meeting date changes. Rebuilding derives paths from the files. No source-document schema change or folder migration is needed.

# Technical debt

When no usable index mapping or cached path exists, recovery scans immediate children of `meetings/` and rejects ambiguous identities. This also recovers externally renamed dated folders. Normal indexed access and new app-created meetings avoid this scan. Repeated missing-ID requests before reconciliation can therefore cost a directory scan; finish or rebuild the disposable index before assessing large-library lookup performance. No separate connection is opened per lookup. Rebuild adds a bounded-memory pass over folder names, using a temporary SQLite count table, before metadata publication so enumeration order cannot select a duplicate copy.

The existing nonthrowing display-path API cannot report an access error. It now returns a nonwritable path beneath `/dev/null` on failure, while throwing storage APIs report the actual error. This compatibility bridge prevents writes to a wrong or external folder without changing UI in this storage task. Finder reveal may still receive that unavailable path. Replace display-path callers with an optional or throwing API, disable unavailable reveal actions, and then remove the sentinel. Folder checks do not provide descriptor-based protection against another process swapping filesystem objects between validation and use.

# Validation

Seven synthetic tests cover local-date boundaries, identity preservation, date edits without renaming, mixed old/new discovery and indexing, metadata edits and deletion reconciliation, archive and Rust-library import dates, recording path reservation across midnight, and library paths with filesystem aliases. The initial corrected focused run passed 47 tests in 8 suites. After the final Rust import fix, the expanded isolated run passed 62 tests in 11 suites, including existing paging, monitoring, recording finalization, audio import, notes, meeting-store, and legacy-speaker import tests. Strict formatting and diff whitespace checks passed.

Before the duplicate, registry, and symlink review fixes, isolated `make build-macos` passed in 50.14 seconds, including Info.plist validation, ad-hoc signing, and signature verification. The coordinating agent also reported a combined release Preview pass in 63.99 seconds. These earlier builds do not validate the subsequent guard changes. They retain the existing missing Command Line Tools search-path linker warnings documented in [macOS release validation](2026-09-30-macos-release-ci.md). The initial dependency build also emitted the documented obsolete `-single_module` configure-probe warning and vendor libtool diagnostics; no new app API deprecation was introduced. Intel and real recording hardware were not tested in this task. The combined full serial test run is tracked by the coordinating agent.

Five additional guard tests cover duplicate rebuild and recovery, incremental conflicts without overwriting either copy, cached/indexed symlink replacement, a symlinked parent directory, and both replacement and transient index lifetimes. The final guard sources, including typed creation errors, passed 67 tests across 12 suites serially. Strict formatting and diff whitespace checks passed. The isolated release build of these final guards passed in 88.95 seconds, including Info.plist validation, ad-hoc signing, and signature verification, with the existing CLT search-path warnings. Production folder sources are frozen for combined validation.

The initial test run exposed two path issues, now corrected: parent-folder comparisons must compare normalized path strings rather than directory-hint-sensitive URL equality, and cached folder names must be resolved against the caller's library URL so transaction path checks continue to work with filesystem aliases. The transaction guard was not weakened.

No UI changes or real library migration were needed.

## Combined validation

Combined validation passed: 517 tests in 96 suites (66.864 seconds), strict Swift formatting/lint, and isolated `make build-macos` (54.65 seconds), including signing. The build retained the documented missing Command Line Tools search-path linker warnings. No new API deprecation warning appeared. The real recording and running app bundle were preserved.

Commit `3ceb78f` was pushed to `master`. [Release CI](https://github.com/rankun203/meeting-notes/actions/runs/36816224156) passed on macOS 15, 26, and 27.
