---
title: Explicit transcript library migration
date: 2026-10-03
status: complete
scope: transcript-migration-tool
---

## Problem

The canonical JSONL app correctly refused legacy saved arrays, leaving existing meetings unavailable until their library was converted. The user requested migration of the current library and a reusable command for other users.

## Implemented solution

Added a standalone standard-library Python command and usage guide under `apps/client-macos-swift/scripts/migrations/`. Dry run is the default. Applying requires the app to be stopped and a new external backup directory. The command verifies a complete file-hash backup, preserves every segment field, publishes JSONL atomically, verifies decoded rows, removes verified predecessor arrays, and checks all unrelated files are unchanged. Existing revisions and legacy live artifacts remain intact. No app reader or startup migration was added.

## Reasoning

The saved array is the existing display authority. Converting it exactly avoids replaying raw events or choosing an older live snapshot over an edited transcript. The user's explicit request for shareable migration tooling supersedes the earlier temporary-script convention for this command. Ambiguous live-only data is refused for review with the previous app. Empty snapshots with no phrases or edits do not justify resurrecting transcript content.

## Technical debt

Legacy live artifacts remain on disk because they may contain distinct historical evidence. They are not synthesized into selectable revisions or current checkpoint metadata; historical completion and gap state may therefore be unavailable in the new UI. A separate reviewed conversion or removal can follow after comparing versions and retaining the backup. The tool does not coordinate with arbitrary external editors; it checks process state and file hashes, and the app and other library writers must remain stopped during migration.

## Validation

Thirteen synthetic tests cover Unicode and embedded newlines, full backup equality, unrelated-file preservation, repeat runs, conflicting JSONL, empty and unresolved live snapshots, invalid times and identities, symlinks, running-app refusal, source and destination changes after planning, existing backup refusal, embedded legacy data, and checkpoint conflicts. The requested local library migration completed with exact decoded equality for every converted segment and a SHA-256-verified full external backup. A final inventory confirmed all unrelated files were unchanged. The installed app reopened, and the previously blocked meeting displayed its transcript, speaker badges, and history control without the migration error. No real content, titles, identities, or library identifiers were copied into repository fixtures. No Swift source or UI layout changed.
