---
title: Keep persistence work off the main actor
date: 2026-10-05
status: implemented
scope: swift-persistence
---

## Problem

The responsiveness audit identified synchronous journal reads during rendering, whole-library external reloads, and main-actor task, notes, and document writes. These operations can delay playback controls and other input even when network requests are asynchronous.

## Implemented solution

The user authorized the follow-up refactor after reviewing the audit. External reloads now retain affected meeting IDs and apply background snapshots only when their revisions remain current. Task presentation uses memory projections; serialized task commands await journal commits before provider work. Notes and canonical document writes use background workers with explicit completion barriers. The detailed implementations are recorded in the external reload, task persistence, notes persistence, and canonical persistence worklogs for this date.

Visible edits and task reservations update immediately. Durable success requires a completed commit. Derived indexes may refresh afterward. Library switching and quit must drain admitted writes. Cancellation must not abandon a transaction after its commit sequence starts. Failed older writes must not erase newer edits.

Meeting loading is now explicit and asynchronous; the meeting getter only returns loaded state. UI actions await the required data or durable operation. A playback intent token rejects delayed loads after Pause, seeking, clearing playback, or a newer playback request. Meeting detail shows loading and retry states when needed.

Concurrent consumers share a cold meeting load; cancelling one consumer does not cancel another. Context chat explicitly loads its matching meetings and captures their content before requesting a response. Meeting and context chats stop before provider submission if saving the user message fails. Speaker-label results revalidate the latest meeting after awaiting task binding, so edits made during a slow binding write survive.

## Validation requirements

Use synthetic fixtures and controlled slow-storage gates to verify that the main actor remains available. Cover duplicate enqueue, no provider request before intent commit, stale reload rejection, latest notes edits, conflicting disk changes, save failures, and quit flushes. Run affected tests and a combined release build after integration. Existing UI changes retain their separate worklogs and before/after captures.

The first focused run passed canonical save, external reload, and deferred playback regressions. The task run passed 68 tests. The combined run covered 217 tests in 34 suites; its remaining failure was a fixture that expected immediate object deallocation instead of awaiting shutdown. After correcting that fixture, all 28 tests in the affected task, recovery, and canonical suites passed. Earlier integration failures also caught missing explicit cold loads, voice reconciliation ordering, and a notes test gate whose independent timeout conflicted with the main-actor test deadline; these were corrected and passed the combined rerun.

Review found that freezing writes before quit caused the public notes flush guard to skip pending notes. Shutdown now drains notes directly, and the regression verifies a pending final edit with no intervening canonical save. Formatting, lint, and diff checks pass. The Xcode release build passed in 162.70 seconds with no compiler warnings and passed platform/signature checks. Its isolated Preview revision is `40e64af-async-review`; the installed app was preserved. The initial sandbox attempt could not run Swift's nested manifest sandbox; the authorized retry completed successfully. After-build synthetic UI checks confirmed a notes edit survives immediate navigation away and back, in both editing and reading views. Privacy opens promptly and dismisses; summary instructions accept input and cancel. At this validation checkpoint, changes had not been pushed and remote CI had not run.

## Technical debt

Transcript history preservation, ordinary voice commands, import/setup work, and some index paging retain synchronous boundaries described in the canonical worklog. They need separate ownership and profiling before conversion; this refactor does not claim to remove every filesystem operation from the main actor. Profiled transcript history reads now run asynchronously; repeated wrapped-text measurement remains a separate layout concern. Ordinary voice commands report a retryable busy error while a staged voice transaction owns persistence. Nonmanaged chat and archive provider operations retain their existing lifecycle: quit drains admitted writes but does not wait indefinitely for a remote reply. User messages and existing archive checkpoints are saved before their downstream operation; a reply still in flight can be lost when the process exits.
