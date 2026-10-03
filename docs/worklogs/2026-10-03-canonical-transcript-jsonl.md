---
title: One canonical transcript in JSONL
date: 2026-10-03
status: complete
scope: swift-transcript-storage
---

## Problem

The streamed live projection and editable transcript stored the same speech in separate formats. Stop still generated and published an editable transcript from the live rows. The user requested one saved segment format for recording, display, provider results, and edits, including recovery after the process is killed.

## Implemented solution

The authority is `transcript.jsonl`, with one timed display segment per line. A small `transcript-checkpoint.json` commits the stable prefix and recent replaceable rows. Stable paragraphs append during recording; Stop drains remaining rows and publishes completion metadata. Deliberate edits may atomically rewrite this compact transcript. Provider results normalize to the same store; prior versions remain only as intentional revisions.

The obsolete CSV raw-event writer, replay decoder, separate live snapshot, duplicate segment projection, and unused in-memory raw-history snapshot chain are removed. Transient recognition and speaker attribution still process incoming audio results; they no longer retain a second historical stream for later replay. Recording metadata saves do not own or roll back the concurrently appended transcript. An atomic edit transaction covers both the canonical rows and checkpoint; interrupted writes recover the previous committed pair.

Local data receipts, generated library guides, and current storage documentation name the canonical file. The website archive's `transcript.json` artifact remains a remote protocol envelope, not a second local transcript. Custom library instructions are preserved and receive a versioned section that supersedes older storage guidance.

## Reasoning

The canonical format must be shared by readers and writers. Renaming the live projection alone would leave full conversion at Stop and allow unrelated meeting metadata saves to overwrite a recording's newer rows. Stable rows and a replaceable tail support appends, while explicit edits use a transactional replacement rather than an update-event log.

The repository's pre-1.0 storage contract requires a temporary verified migration tool, not shipped legacy readers or dual writes. The new build must not interpret unresolved old data as an empty transcript.

## Migration preparation

The temporary tool `/private/tmp/gday-migrate-canonical-transcript.py` defaults to a dry run. Applying requires a stopped Gday Meetings process and a new backup directory outside the library. It copies the library, verifies source bytes, writes one JSON object per line, reads the result back for exact segment equality, and only then removes the old `transcript.json`. Existing conflicting JSONL and unresolved live-only data stop migration. Legacy live artifacts remain untouched for separate history review; the script does not guess which alternate live text to discard.

Synthetic checks passed for Unicode and embedded newlines, timing and ID preservation, verified backup, repeat dry-run, and refusal of live-only data. No real library migration or app installation was performed. Run a stopped-library dry run and resolve any old live-only recordings before installing this build over development data.

## Technical debt

No dual writes or automatic legacy compatibility path remain. Existing pre-1.0 libraries require the explicit conversion described above; unresolved live-only files require the previous app. The temporary migration tool deliberately retains old live artifacts for history review rather than deleting potentially distinct transcripts. Remove those artifacts only after their history has been reviewed and backed up.

The app still loads the compact segment document for display, and explicit edits rewrite it. This is the accepted current size tradeoff, not a raw event replay. If segment documents become large enough to affect editing, add paging or a segment index without reintroducing duplicate authoritative transcripts.

## Validation

Complete diff review, `make format-macos`, `make lint-macos`, and `git diff --check` passed. The final full serial Swift suite passed 703 tests in 119 suites (76.191 seconds), including canonical appends, checkpoint recovery, interrupted edit rollback, recording metadata ownership, preserved source identity, speaker association after sealing, external JSONL edits, provider results, and transcript history. Obsolete CSV/journal tests were removed with their implementations. The final isolated `make build-macos` release build passed in 155.50 seconds; its source tree matched this checkout. Existing linker warnings remain for missing Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search paths. No deprecation warnings were reported. This task commits locally; no push or CI run was requested. No controls or layout changed. Synthetic preview receipt filenames follow the new format. Endurance CPU and memory measurements have not been repeated; eliminating raw replay does not establish that every possible Stop-time spike is gone. A killed process may lose updates that have not reached the latest checkpoint; committed rows and checkpoint tail remain readable. The installed app and user recordings remain untouched.
