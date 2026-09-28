---
title: Durable task journal and recovery
date: 2026-09-27
status: implemented
scope: swift-task-storage-and-recovery
---

## Problem

The task queue rewrote one snapshot file, grouped rows by transient status rather than creation time, and required manual recovery after relaunch. Retrying could create another row for the same request. Missing provider jobs offered no restart path, while dismissing their rows could leave hidden pending requests. A wake event could precede a network failure and leave the task waiting for another wake.

## Design and implemented solution

### Journal and identity

`ManagedTaskJournal` stores independent versioned upsert and delete events in `tasks.jsonl`. Each complete newline-terminated event contains a stable task ID and a full row snapshot. Appending and synchronizing an event commits an intent before provider work starts. Retry, Resume, and Restart preserve the row ID and creation date; explicitly new work after completion creates a new row. Request identity is the transcription attempt's idempotency key, distinct from the row ID and the provider's remote job ID.

Replay reads 64 KB chunks, folds the latest event for each task, and records the latest row's byte offset. Dismiss appends a tombstone. Only an incomplete final write is discarded before a later append; committed lines are never rewritten. Complete malformed records or unsupported journal schemas stop writes and leave the file unchanged. Before repairing a torn tail, the writer verifies the observed file length, so it cannot erase bytes appended externally after replay. `managed-tasks.json` is neither read nor migrated.

Kinds use stable raw strings. Unknown task kinds remain readable and appear as unsupported tasks needing attention; they never silently complete. Transcription and summary executors currently have separate limits of two and one. Other existing background activity remains visible separately.

### Recovery and completion

Launch and wake share one recovery path, with a scheduling guard preventing duplicate local operations. Unsent queued work resumes automatically. Known transcription jobs resume polling their saved remote ID, and transient polling failures retry with increasing delays capped at 30 seconds. Cancellation remains local Stop Waiting; it records the user's stop before cancelling and does not claim to cancel remote processing.

An interrupted summary may already have been processed, so it requires explicit Retry. Ambiguous RunPod submissions without an ID do not resubmit. A row previously bound to a request cannot start another request when its saved checkpoint disappears. A missing job is recognized only from HTTP 404 on a saved transcription job's status operation, and offers explicit Restart. Restart durably records intent, clears only the matching expired checkpoint, and queues a new submission under the original row ID.

Each meeting stores at most one completion receipt per task kind. The receipt is written atomically with the validated generated result. Recovery sees that receipt and completes the row without contacting the provider, even if the app exited before the terminal journal event. Applying a saved transcript also completes its original task after saving succeeds.

Dismiss records its intent before clearing a matching pending request and appending a tombstone. It never clears a later request with a different idempotency key. Interrupted dismissal and restart intents finish on recovery.

### Tasks presentation

The supplied screenshots showed duplicate task rows and state-based grouping. The reviewed design uses one list sorted by immutable creation date, newest first, with creation times visible on each row. Scheduler priority is separate, so Run Next changes execution order without changing creation order. Rows show Resume, Retry, or Restart when applicable. Restart explains that it sends the recording again; Dismiss explains that it discards the saved request and cannot stop remote work. Preview includes an expired task and distinct creation times; its Restart action completes locally without networking.

## Reasoning

Full-row events let future task types add fields without requiring replay of task-specific patch logic. A stable task identity separates retry history from new requests. Per-meeting completion receipts close the gap between saving output and recording task completion. Request identity comparisons protect later jobs from stale row actions. Separate concurrency budgets keep long-running transcription from blocking summaries.

## Technical debt

The journal is append-only and currently has no compaction. It streams replay but retains the latest rows and offset index in memory. Cursor ordering is available by creation time and task ID; efficient cold-start pagination will require a persisted latest-row offset index and a deliberate compaction policy. JSONL alone does not provide scalable pagination. This is accepted because it avoids whole-file rewrites now while preserving the information needed for that index.

Writes are serialized by the application's main actor. File-length checks detect another writer changing the file; concurrent multi-process writers are unsupported and require reopening the library. A future multi-process mode needs locking around append/recovery, not removal of the conflict check.

## Validation and limits

Tests cover committed-prefix preservation, updates and tombstones, creation cursors, torn-tail recovery, complete corruption, external changes before tail repair, unknown kinds, retry identity, automatic same-ID recovery, wake followed by HTTP 503, bounded concurrency, polling beyond the former limit, missing-job Restart, unrelated endpoint 404, matching-request dismissal, completion receipts, explicit Apply, queued versus interrupted summaries, journal write failure, ignored old snapshots, and Preview-only actions.

Restart tests validate the durable reset and scheduling of a new request, then stop before upload. Existing transport tests validate upload and submission separately. No live provider job was submitted. The integrated suite passed 365 tests across 73 suites (`/tmp/gday-storage-stream-verified-tests.log`); Preview build, formatting, lint, and diff checks passed. Known Command Line Tools linker-search-path warnings remain; no new deprecation warning was reported.

The wake observer uses NSWorkspace's notification center and removes its observer on release. A synthetic notification test verifies delivery and cleanup. Real sleep/wake and third-party provider execution were not exercised.

Post-change native screenshots and interaction checks remain unverified: computer use returned `cgWindowNotFound` after the isolated Preview was relaunched, including a fresh-state launch. The initial Summary baseline was captured successfully earlier in this task, and the supplied Tasks/Defaults screenshots informed design. Production data, jobs, and the installed app were left untouched.
