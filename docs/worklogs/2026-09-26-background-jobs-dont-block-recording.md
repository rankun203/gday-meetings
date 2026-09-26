---
title: Record while background tasks continue
date: 2026-09-26
status: implemented
scope: client-macos-swift
---

## Problem

The shared busy flag disabled New Recording while transcription, summaries, chat, archiving, or audio imports were running. One task also prevented unrelated actions on other meetings.

## Implemented solution

- Replaced the busy flag with jobs identified by operation and meeting or chat context. Duplicate requests for the same operation stay disabled; independent tasks can run together.
- New Recording checks library write access and the recording lifecycle. Stop & Save returns after saving audio, with automatic transcription continuing in a separate task.
- Updated the window, menu bar, keyboard command, setup dialog, and per-meeting controls. Background progress remains visible during recording and identifies each meeting.
- Audio imports reserve their target meeting, preventing transcription or archiving from reading a changing track list. Imports remain serialized, while jobs on other meetings continue.
- Kept result updates based on current meeting data. Context chat now appends replies to current history after waiting for the provider. A pending transcription cannot be discarded while its request is running.
- Prevented deletion of a meeting while its jobs are running, preserving files and saved request state until those jobs finish.
- Restricted delayed capture-failure callbacks to their original recording so they cannot stop a newer recording.

## Reasoning

Recording availability depends on audio capture and saving, not network activity. Per-operation jobs preserve duplicate-request protection without blocking independent work. Imports need an additional target reservation because they change the audio inputs used by transcription and archives. Archive metadata remains a snapshot; later edits make that archive out of date rather than changing an upload in progress.

## Technical debt

The existing shared error alert remains: simultaneous task failures can replace its message. This task retains it to keep error presentation consistent. A future per-job result history should preserve failures with meeting and operation labels. No database or schema changes were needed.

## Validation

Added regression coverage for duplicate jobs, independent meeting progress, recording availability, read-only libraries, failure cleanup, deletion, pending-request discard, and import conflicts in both directions. Migrated tests that used the removed busy flag.

Integrated validation passed: formatting, lint, all 199 tests, Preview build, and installer staging. Preview checks covered meeting detail, synthetic meters, recording setup, and keyboard dismissal. Live concurrent provider jobs were not submitted. Command Line Tools emitted missing linker search-path warnings for its absent `Developer/Library/Frameworks` and `Developer/usr/lib` directories; no deprecation warnings appeared. These toolchain warnings remain unsuppressed; verify after the next Command Line Tools update.

Added a real loopback HTTP test for summary and chat operations after that validation. The fixture holds the provider response while the test checks recording availability, repeats the same action, and edits the meeting title and notes. After releasing the response, it verifies one request, retained edits, persisted results, and job cleanup. Both held-response cases passed in the subsequent integrated suite.

Final integrated validation passed all 217 tests in 43 suites, formatting, lint, and diff checks. Known Command Line Tools linker search-path warnings remain; no deprecation warnings were reported.
