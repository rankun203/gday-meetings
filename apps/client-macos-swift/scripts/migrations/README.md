---
title: Library migration commands
date: 2026-10-03
status: active
scope: manual-library-migration
---

# Saved transcript arrays to JSONL

Use `transcript_jsonl.py` to convert the local `transcript.json` segment arrays used before the canonical JSONL change. This is an explicit maintenance command, not an automatic app migration. It requires Python 3.10 or later and uses only the standard library.

Quit every copy of Gday Meetings before applying. Keep it closed until verification finishes. Run from the repository root, replacing the library path if Data settings points elsewhere:

```sh
uv run --no-project python apps/client-macos-swift/scripts/migrations/transcript_jsonl.py \
  "$HOME/.local/share/com.gdaymeetings.macos"
```

The default is a dry run. Apply with a new backup directory outside the library:

```sh
uv run --no-project python apps/client-macos-swift/scripts/migrations/transcript_jsonl.py \
  "$HOME/.local/share/com.gdaymeetings.macos" \
  --apply --backup "$HOME/.local/share/gday-meetings-backups/before-transcript-jsonl"
```

A normal Python installation can run the same command with `python3` instead of `uv run --no-project python`.

The command copies the entire library and verifies every file with SHA-256 before changing transcripts. Each saved array becomes one JSON object per segment line. Text, times, identities, speaker assignments, and unknown fields are preserved. It verifies decoded rows before removing each old array and checks that every other file remains unchanged. It refuses conflicting existing JSONL, malformed segments, symlinks, and unresolved live-only data. A repeated run after completion makes no changes.

Existing `transcript-revisions.json` and legacy live artifacts remain byte-for-byte unchanged. Older live snapshots are retained on disk; this command does not turn them into new selectable revisions or replay raw recognition events. A saved empty array remains empty only when its legacy snapshot has no saved phrases or edits. If the command reports unresolved live data, recover or review that meeting with the previous app before conversion; it will not guess which version is authoritative. No new live checkpoint is synthesized, so historical live completion or gap metadata is not newly attached to the canonical transcript.

After success, reopen the app and select a meeting. Keep the backup until content and assignments have been reviewed. If interrupted, leave the app closed: rerunning accepts already converted meetings and matching JSON/JSONL pairs. Use a fresh backup destination for another apply. The original full backup remains the recovery source; restore it to a separate library folder and choose that folder in Data settings if needed. Do not overlay it onto an open library.

Run synthetic checks with:

```sh
uv run --no-project python -m unittest discover \
  -s apps/client-macos-swift/scripts/migrations -p 'test_*.py'
```

# Rust library import

Use `rust_library.py` to copy a stopped Rust library into an existing Swift library. It requires Python 3.11 or later. Quit both apps and pause external library editors until verification finishes. An isolated UI Preview bundle may stay open; its library is temporary.

```sh
uv run --no-project python apps/client-macos-swift/scripts/migrations/rust_library.py \
  "$HOME/.local/share/com.gdaymeetings.macos.rust" \
  "$HOME/.local/share/com.gdaymeetings.macos" --embedding-origin runpod
```

The required `--embedding-origin runpod` flag confirms known source provenance; do not use this command for embeddings from an unknown provider. Review the dry-run counts, then add `--apply --backup /path/to/new-backup-folder`. The backup folder must be new and outside both libraries. The command verifies a full destination backup, stages imported files, checks source and destination hashes again, and publishes without replacing existing files. It verifies the resulting inventory and leaves source files unchanged. Both applications and other library writers must remain stopped; filesystem checks do not lock out arbitrary external editors.

Meetings receive stable IDs, canonical `transcript.jsonl`, notes, summaries, to-dos, speaker assignments, and copied audio and attachments. An exact complete audio-file hash match reuses an existing meeting and preserves its current content. Source artifacts remain in that meeting's `legacy-rust/` folder. Unsupported fields, transcript word details, profile history, tag notes, and conversations remain in `legacy-rust/` or `rust-import-archive/`; archived conversations are not added to the current chat interface. Audio is copied once. Settings, secrets, caches, and logs are not imported.

People receive stable separate identities; names alone do not establish that two profiles belong to the same person. All confirmed voice samples, including duplicate confirmations, retain their exact vectors and `legacy:rust:runpod` provenance. Rust samples do not identify the embedding model and revision, so they retain the Swift `unknownLegacy` compatibility type. They are preserved for recovery and future conversion but do not qualify for typed automatic speaker matching. The tool does not normalize vectors or label them as a current model. A sample links to a speaker only when the source meeting, assigned person, and exact vector identify one speaker; otherwise it retains a stable unresolved speaker ID and its source evidence in the archive.

Invalid optional meeting-speaker vectors are omitted from the current speaker record and retained in the archive. References to deleted source profiles remain unresolved instead of creating a person. Existing same-name tags keep the destination's exclusion setting. The dry run reports these cases, and `.rust-library-import.json` records private source mappings, source hashes, output paths, and review details including name overlaps. Review those details after importing.

A repeated run with the same source preserves subsequent destination edits and makes no changes. A changed source or missing imported file stops the command for review. After an interrupted publication, keep both apps closed; a fresh run accepts already published files only when their bytes match the planned import. Use a new backup folder. The original destination backup and unchanged Rust library remain recovery sources. Do not overlay a backup onto an open library.

After the import, rebuild the disposable search index before reviewing the imported library. This command preserves the existing index files; it does not claim that their cached entries include imported meetings. Keep the app closed while moving the old index and event-cache files to a separate recovery folder, then reopen the app to rebuild from the authoritative meeting files.
