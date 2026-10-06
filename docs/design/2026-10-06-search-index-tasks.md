---
title: Search index task behavior
date: 2026-10-06
status: proposed
scope: macos-search-indexing
---

# Problem and evidence

The supplied Data and Tasks screenshots show a rebuild with a disabled button, stale “Search index is up to date” text, no progress bar, and many individual meeting tasks. Completed rows occupy the visible task page while the footer reports running and queued work. The user also reports severe interaction delays. This document proposes behavior; it does not claim the changes are implemented or that the stall has been profiled.

# Current behavior

| Evidence in source | Consequence |
| --- | --- |
| `LocalSearchController.swift`, `scheduleSearchIndexing`: sets plain scan flags, waits two seconds, checks the model, resets the selected projection, then discovers meetings in pages of 20. Status changes only after discovery finishes. | No immediate, observable preparation state. The old up-to-date message remains visible during work. `scanTask` is not published, so it is also an unreliable direct source for the button's disabled state. |
| `DataSettingsView.swift`, `SearchIndexSettings`: displays progress only when `controller.progress` exists. `performSearchIndex` sets that value from provider passage callbacks and clears it after each meeting. | Discovery, model preparation, source reading, window construction, and the gaps between meetings have no progress indicator. There is no whole-build progress. |
| `ManagedTasks.swift`, `ManagedTaskRecord` and `queueSearchIndexCommand`: every task requires one meeting ID and loads that meeting into the UI store before enqueueing. Each enqueue persists a task and invokes scheduling. | A rebuild becomes hundreds of separate task records and repeated store publications, although the provider independently reads the meeting again. |
| `SemanticSearchProvider.swift`, `updateIndex`: emits one callback per window, including reused vectors. `performSearchIndex` creates a main-actor task for every callback. `recordManagedTaskProgress` replaces the published task cache. | Fast reuse can generate a large burst of UI updates. Progress is transient rather than durably written per passage, but the UI notification volume remains high. |
| `ManagedTasks.swift`, `runManagedTask`: every successful search task requests another whole-library freshness scan. | Work completion feeds discovery again. The two-second debounce coalesces some requests, but does not remove repeated whole-library scans during a long rebuild. |
| `TaskQueueView.swift`, `refreshRows`: refreshes a page around its existing first row and fetches at most one newer predecessor. `TaskHistoryPage.swift` orders by creation time, not active state. | Preserving history position also preserves completed rows while new or running tasks remain outside that page. Counts represent the whole journal, so the footer and visible rows can appear inconsistent. |
| `NativeTaskList.swift` derives most kind labels using `rawValue.capitalized`. | The list says “Searchindex” while task details say “Search Index”. |
| `SemanticSearchIndex.swift`, `reset`: deletes the selected model's projection before replacement work starts. Rebuild then calls `updateIndex(rebuild: false)`. | Search coverage is reduced during rebuild. Valid saved embeddings are reused; this action rebuilds the projection rather than necessarily recomputing every embedding. |

These mechanisms explain missing progress and task proliferation. They identify plausible sources of UI pressure, not a proven main-thread stall root cause. Core ML and tokenization already run on their own actor, while source reads, fingerprints, and much task I/O use background work. Profile main-thread scheduling, published meeting equality checks, task-view refreshes, SQLite waits, and filesystem notifications before attributing the freeze to inference.

A separate startup measurement observed search-task failures with “This task changed outside the app. Resume to continue.” while another app could access the same library. The measurement app was stopped. This is evidence of a concurrent-writer problem in that run, not proof that it caused the supplied screenshots. `reloadExternalManagedTasksCommand` deliberately marks externally changed active records as needing manual recovery.

# Proposed behavior

## Common contract for every task

All task types must share timing, status, identity, and progress semantics: search indexing, transcription, summaries, speaker labeling, voice preparation, imports, exports, and other operations shown in Tasks. This is a universal task requirement, not an index-specific addition. Provider-specific payloads and checkpoints remain separate from the common envelope.

| Field | Required meaning |
| --- | --- |
| Stable ID, type, target, title | One user operation with a typed target: one meeting, multiple meetings, a person, or the library. |
| Status | Queued, running, paused, completed, completed with errors, failed, or cancelled. Recovery availability is separate from status. |
| Created / queued time | When the intent was recorded and when the current attempt entered the queue. Queue waiting is not execution duration. |
| Start time | Actual first transition into execution. Persist it before dispatching work. It is absent for a task that has never started. |
| End time | Actual terminal transition for the operation or attempt. Absent while running or paused. Cancellation before execution can have an end time without a start time. |
| Duration | Wall time from the operation's first start to now or its end, including pauses and retry waits. Label it **Elapsed** when those intervals matter. Never derive it from creation time. |
| Active duration | Sum of executing intervals across attempts, excluding queued, paused, and app-closed intervals. Label it **Active**. Running may include waiting for a provider response; this is not CPU time. |
| Progress and phase | Structured phase plus optional completed/total units; unknown totals remain indeterminate. |
| Outcome and error | Result summary, structured failure and affected targets, recovery actions, and interruption reason. |
| Attempt history | Stable attempt IDs, queued/start/end times, status, and execution intervals. Preserve failed attempts when retrying. |

Pause and resume continue the same operation and attempt, adding execution intervals without overwriting the original start. Retry after a failed attempt creates another attempt under the same operation; the previous attempt's end, failure, and duration remain intact. An explicitly new run after completion is a new operation. If reopening a failed operation for retry clears its current operation end time, the attempt history still retains the prior terminal event. A resumed operation retains its original start-time position; attempts have their own timing inside its details.

Use wall-clock timestamps for displayed dates and a monotonic clock for measured intervals within a process. Persist accumulated active time at checkpoints. After a crash, an uncheckpointed interval is unknown rather than silently counted through app downtime; show an incomplete measurement where necessary. A task cancelled before starting displays **Not Started**, **Duration: —**, and its cancellation time. Legacy unknown timing displays **Not Recorded**, not a fabricated duration or start.

Each task row shows its common status, start time, and live/final duration. Details consistently show **Queued**, **Started**, **Ended**, **Elapsed**, and **Active**, with appropriate absent-state labels. A compact row can read “Running · Started 10:30 pm · 2m 14s”; queued rows read “Queued · Not Started”. Progress and provider-specific details supplement these fields.

Current gaps: `ManagedTaskRecord` has `createdAt`, `finishedAt`, and status, but no actual start or execution intervals; retries clear `finishedAt`. `VoicePreparationJob` has `createdAt` and status but no start or end. `BackgroundJob` has only kind, scope, and progress. `TaskHistoryRow`, journal cursors, and `ManagedTaskIndex` currently sort/index by creation time. Implement the common envelope across these representations rather than adding timing only to search tasks. Version the durable schema and rebuild disposable indexes. Preserve trustworthy existing finish timestamps, but leave missing start/active duration unknown unless an authoritative timestamped event exists; do not infer them from creation time, file dates, or journal offsets.

## One operation, one visible task

A rebuild creates one durable **Rebuild Search Index** task immediately, before discovery. Its target is the library and a pinned provider/model space; its child work items represent one or more meetings. Incremental updates use the same task type, titled **Update Search Index**, with a deduplicated set of meeting IDs and source revisions. Do not create hidden managed tasks per meeting or use a fabricated meeting ID to satisfy the existing schema.

Extend the managed task target explicitly to support a meeting or a search-index batch. Store child checkpoints in an indexed table, rather than an unbounded array rewritten on every progress update. Keep task identity, phase, target model, counts, and recovery state in the parent. Apply the common task envelope to every task type. Consolidate meeting-scoped search tasks without changing how transcription, summary, or speaker-labeling work executes. Existing completed history stays readable; pending compatible search items can be consolidated once, preserving cancellation and source revision intent.

A fixed rebuild snapshot gives meaningful totals. Newly changed meetings become a deduplicated follow-up update batch; a small number may be prioritized between rebuild meetings without creating one visible task per change. Live transcript updates coalesce confirmed revisions and reuse unchanged windows. A source change while an item runs invalidates that item's attempted revision and queues the newest revision once. Do not rescan the entire library after each completed meeting.

## Immediate and continuous progress

Publish a typed state before starting background work: queued, discovering, preparing model, indexing, saving, paused, completed, completed with errors, or failed. Data and Tasks observe the same snapshot. Show an indeterminate bar while totals are unknown, followed by determinate meeting progress. Show passage progress for the current meeting separately; do not label a meeting-weighted percentage as elapsed-time progress.

Example Data content:

> Rebuilding search index · 42 of 120 meetings\
> Current meeting: Planning discussion · 18 of 64 passages\
> [progress bar]\
> **Show Task** · **Pause** · **Cancel**

Example task details show the same totals, model, elapsed time, current meeting, and a paginated meeting list with status. A single-meeting task can show **Open Meeting** directly. Multiple-meeting tasks offer **Open Meeting** on each item. Errors remain attached to the affected meeting with **Retry Failed Meetings**; successful work is retained.

Use explicit “Preparing search index…” or “Loading search model…” phases. Never display “Search index is up to date” until discovery and all relevant active work have settled. Repeated Rebuild clicks reveal the existing operation instead of creating duplicates. **Rebuild Search Index** is disabled while that same rebuild exists, with the current task and its controls visible in its place.

## Keep the app and search usable

A dedicated background coordinator owns discovery, source loading, tokenization, embedding, and persistence. It should not hydrate the general UI meeting cache to enqueue index work. Publish compact progress snapshots at a bounded rate, for example at most four updates per second, with immediate phase, error, and completion updates. Persist checkpoints at meeting boundaries and meaningful recovery points, not at every rendered progress update.

Run one indexing worker by default. Interactive search gets priority at the next passage boundary; recording and live transcription retain their own responsiveness. Measure rather than assume that actor isolation alone prevents UI pressure. Avoid an unbounded backlog of main-actor progress tasks.

For a same-model rebuild, retain the usable index while constructing a replacement generation, then atomically publish that generation. Track source changes and deletions before the switch so stale passages cannot reappear. A model change always uses a distinct vector space; never search one model's index with another model's query vector. Staging temporarily costs additional disk space and needs explicit generation cleanup after success, cancellation, or crash. This is preferable to deleting the only working projection first.

The default rebuild may reuse validated embeddings for identical content and model revision. Say so in its explanatory text: “Rebuilds the search index using saved embeddings when available.” A repair that recomputes embeddings should be a separate explicit action if needed.

## Active tasks remain visible

Present **Running**, **Queued**, and **History** sections, with the active sections independent of history pagination. Within each section of started tasks, sort by actual operation start time, newest first, using stable ID as the tie-breaker. History uses this same start-time ordering, not creation or completion time. Running tasks stay visible at the top, and history retains its viewport. Never-started queued tasks have no start timestamp; order that section by scheduler priority, then queued time and stable ID, and show its queue position. Historical tasks without a recorded start sort after known starts, using creation time and stable ID only as an explicit legacy fallback. Apply the same ordering in filtered views and use matching database indexes and pagination cursors; do not merely sort an already loaded page. Do not force selection to jump when a task completes. Keep the existing filters, and make the global task summary open the Active view or reveal the current operation. All views use one display-name mapping for task kinds.

The footer counts operations, not child meetings: one rebuild is “1 running”, while its row says “42 of 120 meetings”. A detail list shows the current meeting first and supports remaining/completed/failed filters without filling the global queue with child rows.

## Pause, cancellation, recovery, and ownership

**Pause** stops at a safe checkpoint and preserves remaining work. **Resume** verifies the pinned model and source revisions, then continues. **Cancel** removes pending intent but keeps the previously usable index and committed reusable embeddings. Cancelled source revisions must not immediately requeue through automatic discovery; an explicit rebuild or a newer revision can create new intent. Closing the app checkpoints the batch for safe recovery rather than producing hundreds of attention items.

Only one process may execute tasks for a library. Establish explicit per-library scheduler ownership with crash recovery; a second app may read status but must not independently resume the same tasks. Test ownership loss and external edits as first-class states, not just generic failures. This needs coordination with the library's existing write protection and journal rules, not an index-only lock that leaves other task writers conflicting.

# Validation before implementation is considered complete

- Test the common task contract across all task types, including queued cancellation, pause/resume, failed attempts followed by retry, clock changes, crash recovery, and legacy unknown timestamps. Verify start-time ordering and pagination with equal starts, newly started tasks, and histories containing missing starts.
- Profile the reported slow interaction using a synthetic large library, including a rebuild that reuses all embeddings. Measure main-thread stalls and input responsiveness, not only total indexing time.
- Verify immediate preparation feedback, continuous progress, accurate completion, and running-task visibility with the history list already scrolled.
- Test one and many meetings; repeated Rebuild clicks; new meetings and live revisions during a rebuild; deletion; archives; model switching; and library switching.
- Test pause/resume, cancellation without immediate automatic requeue, partial failures, restart after each checkpoint, and two apps attempting scheduler ownership.
- Verify search remains usable during same-model replacement and that switching generations preserves source freshness, speaker bonuses, filters, and model-space isolation.
- Capture before/after UI, test keyboard and accessibility labels, and run the relevant regression tests and isolated release build. This analysis makes no production-code change; those validations remain pending.
