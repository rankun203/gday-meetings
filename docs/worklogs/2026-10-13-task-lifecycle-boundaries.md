---
title: Task admission and recovery boundaries
date: 2026-10-13
status: validating
scope: macos-task-lifecycle
---

## Problem

Concurrent-task guards did not prevent an automatic completion callback from creating another task after the previous task completed. An active search task also prevented admission of a newer source revision without explicitly cancelling obsolete work. Rebuild requests needed durable membership so cancellation and recovery could use the existing task queue.

## Implemented solution

`ManagedTasks.swift` and `ManagedTaskCommands.swift` store a source revision for summary and diarization requests. The revision hashes committed transcript words and source identity, plus notes for summaries and audio filenames for diarization. Speaker assignments and chat do not create a different transcription result. Automatic admission searches durable history for the same source, including completed or stopped requests. Explicit retry remains available.

A new source cancels an obsolete summary or diarization operation of the same kind and meeting before replacement admission. Explicit summary requests also supersede changed instructions or providers; identical requests remain guarded. A reservation spans cancellation so an automatic callback cannot take the replacement's place. It does not cancel unrelated task kinds. Search admission reuses the active revision or cancels it and requests a scan after its operation releases the background-job key. Editor suspension uses the same cancellation mechanism without recording a user stop. `MeetingIntelligence.swift` lets a newer committed transcript reach this admission boundary instead of waiting for an obsolete summary.

Rebuild children have an optional batch identifier. Query and cancellation APIs operate on the durable journal. Admission, scheduler start, execution, and startup recovery require the matching rebuild manifest to remain active. This closes the race where cancellation is saved before a late child admission, and prevents queued children from running after a cancelled rebuild is reopened. Search interruption during app shutdown uses automatic recovery. The rebuild manifest and progress coordinator are implemented in the search worklog.

## Numbered scope

| Item | Result |
|---|---|
| 7 | Added same-kind, obsolete-source cancellation. Complete speaker-result saves already form the persistence boundary. |
| 12 | Added durable child membership, batch cancellation, and cancelled-manifest guards. Search owns the parent request and progress. |
| 13 | Retained recording finalization guards and existing automation settings. Indexing remains deferred during capture and finalization. |
| 14 | Retained concurrent transcription admission protection. Provider results save before downstream work. |
| 15 | Added durable sequential deduplication for automatic summary and diarization requests. |
| 16 | Confirmed streaming writes only `summaryDrafts`; one final `updateMeeting` saves the complete result. |
| 17 | Retained explicit diarization admission and added obsolete-source cancellation. |
| 18 | Retained durable voice-job identity across pause and resume. |
| 21 | Added revision-aware search cancellation and same-revision reuse. Search owns scan coalescing. |
| 22 | Retained 100 ms progress throttling and maintenance attention only when intervention is required. |
| 23 | Retained task identity for retry/resume, separate timeline events, and alert acknowledgement without history deletion. |
| 24 | Retained recovery receipt reconciliation; added rebuild cancellation guards and automatic search recovery after shutdown. |
| 25 | Retained transient archive, contextual chat, and repair operations. |

## Reasoning

Use the existing serialized admission queue and durable task journal. Cancellation waits outside that queue because task completion must acquire it to release the old operation. A committed source identity provides sequential deduplication without comparing every meeting field or introducing another scheduler.

## Technical debt

Existing task records decode missing source and batch identifiers as `nil`. Their original committed input cannot be inferred reliably, so pre-upgrade records do not receive retrospective source deduplication. This compatibility limit avoids fabricating provenance; new admissions record the identity. No database schema migration or parallel scheduler was introduced.

## Validation

Added `ManagedTaskSourceTests` for explicit instructions/provider supersession, unchanged-request deduplication, preservation of unrelated queued task kinds, source identity, sequential admission after journal reload, obsolete-summary replacement, search revision replacement, batch cancellation retaining history, and cancellation persisted before child shutdown/recovery. The batch-recovery test also rejects a late admission using the cancelled request. A stopping-child test verifies that a new rebuild cannot adopt the previous batch's cancelled operation before it releases its key. Scoped syntax parsing passed; this does not replace type checking or test execution.

Relevant existing suites cover summary streaming versus saved content, voice pause/resume, transcription admission limits, task receipts/recovery, and attention timing. The final combined run passed 110 tests in 17 suites, including the new source and cancellation cases. Production builds passed. This worklog does not claim live-provider validation; post-change editor/settings UI checks remain blocked by desktop automation availability, as recorded in the parent worklog.
