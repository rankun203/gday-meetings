---
title: Asynchronous task persistence
date: 2026-10-05
status: implemented
scope: macos-task-persistence
---

# Problem

Task admission, scheduling, recovery, and detail reads performed journal and SQLite work on the main actor. Button availability also queried SQLite repeatedly. Moving only append calls to a background queue would allow concurrent commands to overwrite checkpoints or start providers before task intent was durable.

# Implemented solution

- A serial utility worker performs journal reads, index queries, and durable writes. A main-actor FIFO command gate keeps each read–transition–commit sequence ordered across suspension points.
- Queue admission reserves its task key immediately. Other admissions see the reservation without storage access. The scheduler commits queued and running intent before starting provider work, and checks cancellation reservations again after storage returns.
- Provider operations run outside the command gate. Checkpoint callbacks enter the gate separately and await durability. Cancellation cancels the provider operation immediately and schedules its durable transition in order.
- State totals and active-key counts update after successful commits. The active projection covers every active task independently of the bounded 100-record presentation cache. Task availability reads this projection; older detail requests explicitly await a gated read.
- Speaker-label application re-reads the meeting and validates transcript/audio inputs after the durable result binding returns. Edits during slow journal storage are preserved, and changed inputs reject stale labels.
- Quit freezes new task admissions, cancels and awaits existing provider operations outside the gate, and drains their final checkpoints. Interrupted transcription retains automatic recovery; summary and speaker labeling require manual retry. A queued request interrupted before submission stays queued.
- Restore and external reload rebuild projections on the worker. Progress text remains an in-memory update until the next durable transition. A drain API supports the app's quit and library-switch barriers.

# Reasoning

| State | Consistency boundary |
| --- | --- |
| Provider submission intent, request IDs, restart/dismiss intent, terminal state | Await the ordered journal commit before dependent actions. Preserve existing conflict detection and synchronization. |
| Active task admission | Immediate in-memory reservation, then committed projection; reject duplicate admission during slow storage. |
| Progress text | Eventual persistence at the next durable transition; it does not authorize a provider request. |
| Task history/detail | Await an ordered read; publish a bounded payload cache and complete state/key counts. |
| Retry availability | Read memory only; the actual command validates meeting existence before starting. An externally deleted meeting can temporarily retain an action until that validation. |

The command gate never awaits a provider operation. It may await canonical meeting commits for restart/dismiss bookkeeping; these must remain independent of task checkpoint callbacks to avoid a dependency cycle.

# Validation

- The focused Xcode-toolchain debug suite passed **68 tests across 10 suites**, including existing journal corruption, retry, restart, recovery, provider routing, automatic summary, and speaker-task coverage.
- Seven new regressions cover a blocked storage worker with responsive main-actor reads and duplicate admission prevention; FIFO commands after caller cancellation; cancellation before provider submission; scheduler read failures resolving callers without losing durable intent; quit during scheduling; active tasks beyond the payload cache, uncached waiters, and external deletion; and transcription recovery after quit.
- The first run exposed a scheduler failure affecting a different task kind: the queue remained durable but its caller kept waiting. The scheduler now resolves every affected queued caller when its storage query fails. The regression passes.
- Async cold-load fixtures now explicitly await meeting loading. The quit/relaunch fixture preserves provider settings and restores synthetic credentials, matching the other relaunch tests.
- Follow-up integrated review added a blocked-checkpoint speaker-label regression for preserving unrelated edits and rejecting changed transcripts, plus quit admission coverage for nonmanaged jobs. Both passed in the integrated run. Its remaining fixture failure assumed immediate store deallocation; the fixture now awaits the actual quit/drain boundary, and the subsequent focused 28-test run passed.
- The combined release build passed in 162.70 seconds without warnings or errors. Source parsing and `git diff --check` passed.
- In the synthetic release Preview, a Notes edit remained visible in Edit and Read after immediate navigation away and back. Data Privacy opened, displayed its group footer, and dismissed with Done. The summary instructions sheet accepted input and cancelled without submitting a request. These checks cover presentation and persistence interaction, not provider network execution.

# Technical debt

No journal format or database migration is introduced. The bounded presentation cache and complete lightweight active-key projection intentionally serve different roles; restore, reload, commit, and dismissal must keep both projections aligned. Meeting existence in task action availability is eventually consistent and checked authoritatively when the action runs. Transcript history preservation writes remain synchronous and need a separate ordering migration; UI history reads moved to asynchronous snapshots in a companion change. Nonmanaged chat/context/archive requests are not retained as cancellable operation handles. Quit rejects new jobs and drains admitted persistence, but it does not wait indefinitely for an outstanding network response; a pending chat reply may be lost, while its user message remains durable, and archive checkpoints allow resumption. A future change should give those providers tracked cancellation and completion ownership before adding a shutdown drain. This entry does not claim all app storage work has moved off the main actor.
