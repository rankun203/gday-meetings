---
title: Tasks review and processing coordination
date: 2026-10-07
status: completed
scope: swift-macos-tasks
---

# Tasks review and processing coordination

## Problem

Tasks treated execution failure as attention, offered a Dismiss action that deleted saved recovery intent, and presented operation/state without the current problem. External journal reload compared file offsets and event metadata, so a rewrite of unchanged intent could ask for an unnecessary decision. Voice failures lost their source context when identical messages were deduplicated. Integrated validation also ran AppKit fixtures concurrently in one process, allowing unrelated UI work to starve a navigation deadline.

## Implemented solution

- Attention uses the recovery decision and a persisted acknowledgement independently of execution state. Dismiss Alert keeps the task and provider request. Cancel and Discard Task retain their separate effects.
- The task index compares canonical execution intent for external changes. Genuine changed active intent pauses for review. Offset relocation and newly written event metadata do not imply a changed request.
- State transitions retain a timeline across retries. Waiting and local active durations are separate; remote provider requests use waiting time. Existing records without timelines do not invent past processing measurements.
- Presentation adapters describe operation, affected meeting or library, state, current progress/problem, and relevant time. Automatic search-index activity has a separate maintenance view; manually requested indexing remains in ordinary task scopes; failures remain in Needs Attention.
- Local model preparation and inference admission use bounded permits and priorities. Each allows at most two concurrent units, with at most one background unit to reserve capacity for capture and interactive work. Journal I/O retains its existing serial queue. Permits cover actual work rather than idle model residency. Recording suspends maintenance and new background preparation/inference admission; new offline speaker-labeling tasks retain Queued state and a recording wait reason. Scheduler admission rechecks capture after asynchronous journal work. Suspension generations belong to a store owner; releasing one owner cannot resume another owner's recording. Processing units release permits cooperatively.
- The first progress transition is immediate; subsequent progress updates coalesce within 100 milliseconds. Native task tables reload changed rows when identities remain stable. Journal writes remain reserved for meaningful transitions and recovery bindings.

## Reasoning

The existing executors and journals remain authoritative. Attention acknowledgement must not imply abandoning saved work. Canonical execution fields, rather than event location, serialization metadata, or presentation changes, identify an external intent change. A shared coordinator allows local capabilities to compete for bounded resources without separate per-feature schedulers.

## UI design and validation

Before edits, inspected the production Tasks screen in a copied isolated UI Preview bundle with synthetic task fixtures. The existing screen used a 290-point list, two-line meeting/state rows, and a detail pane whose Dismiss action discarded the saved request. The design expands the list to 340 points and three lines: operation/item, problem or progress, and state/time. Detail uses the operation as its heading, retains the affected item below it, and places consequences, recovery actions, timing, and expandable attempt history together. Dismiss Alert and Discard Task use explicit labels. Resolving the selected filtered row selects the next remaining row.

Before bundle: `tmp/tasks-coordination/Tasks Before.app`, copied from Preview revision `759e6fc-dirty`, System appearance, synthetic tasks flag enabled. Screenshot and accessibility observations captured through computer-use tooling. Real capture and hardware playback remain disabled; the running normal app was not rebuilt or closed.

After bundle: `tmp/model-lifecycle-validation/apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`, unique identifier `com.gdaymeetings.macos.preview.lifecycleafter`, revision `lifecycle-after-198abb5`, combined uncommitted sources. The isolated release build passed in 193.20 seconds and its Preview signature passed strict verification. Screenshots in dark and light appearance confirmed the planned layout. Review, the attention filter, and the badge agreed on four alerts. Dismiss Alert selected the next alert; keyboard Down changed the selection. Dismiss All Alerts emptied the filter and cleared the selection while all four failed tasks remained available in Failed. The discard sheet's Keep Task action retained its target. Voice detail kept three identical failures as separate source items with Open Meeting actions. Maintenance showed affected meetings, while ordinary History omitted successful automatic indexing. The legacy voice fixture had no timeline; its detail did not invent historical time. A final adapter repair preserves problem text in acknowledged failed rows, independent of attention.

The final adapter repair passed an incremental isolated release build in 102.51 seconds, followed by strict signature verification. Final screenshot comparison used a copy at `tmp/tasks-coordination/Tasks After.app`, identifier `com.gdaymeetings.macos.preview.tasksafter`, revision `tasks-after-198abb5`. After bulk acknowledgement, Failed retained the transcription, summary, and speaker-labeling problem descriptions and the voice job's three failed-item count. The alert badge disappeared while active work remained visible. The new bundle path avoided a stale computer-use binding to the previous identifier.

Focused Tasks, coordination, paging, speaker-task, and background-job validation passed 42 tests in five suites after review repairs. Earlier fixture failures were resolved by using an immediately loaded voice library for the folder-choice test, explicitly selecting only remote providers in the provider-eligibility fixture, and replacing a short cancellation deadline with a cancellation-driven test worker. The redundant global disk gate was removed because journal I/O already uses a serial queue. Formatting and whitespace checks passed. Preview does not establish inference accuracy, real recording behavior, or performance improvement. No retained traces or videos were removed, and this task created no raw performance traces.

## Integrated test isolation

A diagnostic parallel full run reproduced MeetingSelection and sidebar timing failures among 1,063 tests. Native selection and its SwiftUI binding matched the requested meeting, the disk read had completed, and no read was queued. Main-actor polling stalled for 10.32 seconds; the test's own longest layout call was 77 milliseconds. Five overlapping targeted suites passed 18 tests in 7.113 seconds. Explicit serial execution passed all 1,063 tests in 183 suites in 107.907 seconds; selection passed in 0.553 seconds and sidebar reversal in 2.048 seconds. No deadlines, assertions, or production navigation behavior were changed.

The test script now defaults to `--no-parallel` because its AppKit fixtures share `NSApplication`, focus, and the main run loop. Explicit parallelism flags remain available; the explicit parallel ProcessingCoordinator run passed six tests in 1 millisecond. Tests that exercise concurrent operations still create their own overlapping tasks. This reduces cross-test throughput while isolating process-global UI state. The README records the reason and explicit parallel invocation. Concise read-completion and polling diagnostics remain in MeetingSelectionTests.

The earlier transient deletion-membership assertion did not recur in the diagnostic full run, the serial full run, or 100 bounded repetitions in 4.937 seconds. BackgroundJobTests records membership once and reports memory, index, and file state on failure. No separate production deletion defect was established; the execution-isolation repair must not be presented as proof of that transient assertion's independent cause. The final integrated run through the repaired default script passed all 1,063 tests in 183 suites in 107.044 seconds. Selection passed in 0.572 seconds and deletion in 65 milliseconds. Shell syntax, Swift formatting, lint, and whitespace checks passed.

## Technical debt

None. Existing records retain optional timeline fields for backward compatibility. Historical active time is unavailable until recorded transitions exist; the UI must not estimate it from task creation time. No alternate task executor, model loader, or persistence format was introduced. Earlier builds do not understand new Paused task records or Cancelled voice-job records; use the current build when reopening a library that contains those states.

## Notes

Current source work also includes independent model-capability and search changes. The coordinating agent validated the final combined isolated release in 183.63 seconds with the full Xcode toolchain, macOS 26 deployment minimum, SDK 27, and strict signature verification. No commits or pushes were made by this task.

## Code review

Claude Code reviewed the implementation read-only using `claude-opus-5-5`; both session initialization and responses identified that exact model. The review found recording-start joins that could delay audio capture, shared inference capacity that could stall capture behind background work, invented historical waiting time for legacy tasks, maintenance filtering that hid manually requested indexing, a stale asynchronous resume race, and a library-folder validation order that could pause work after a rejected change.

Repairs start capture without joining whole-recording retirement, reserve capacity for capture and interactive units, begin legacy timing at the first observed transition, keep manually requested indexing in ordinary scopes, version recording suspension/resume events, and validate a folder before shutting down voice work. The intent hash excludes progress, display titles, timeline, acknowledgement, and queue ordering. Timelines use the journal predecessor rather than a possibly stale cache. Explicit Paused and Failed filters preserve access to acknowledged work. Duration text updates only in selected ongoing task details; finished attempts have static totals. Recording-cancelled indexing is classified by the original pause request even when the recording ends before cancellation finishes. Removing the redundant journal storage permit avoids cancellation admission around durable writes and unnecessary cross-library serialization.

Resource admission tests establish concurrency and ordering, not real-time throughput. Whole-recording discovery and speaker labeling use a dependency API that cannot preempt a running unit; capture and interactive admission have reserved capacity beside that unit, and new background inference waits until recording finishes. Actual capture throughput and peak memory remain unmeasured here.

The initial review and follow-up completed with Opus 5.5. A third read-only check after the final repairs was rejected with HTTP 429 because the Claude account reached its monthly spend limit; no code was reviewed by that attempt. The completed reviews and focused validation remain the available evidence. The later test-process isolation and diagnostic changes were reviewed locally; they have not received another Opus review because the quota blocker remains.
