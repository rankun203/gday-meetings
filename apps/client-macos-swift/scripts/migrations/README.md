---
title: Transcript JSONL migration
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
