---
title: Recording-time task alert investigation
date: 2026-10-15
status: complete
scope: macos-managed-tasks
---

## Problem

During recording, the task attention banner displayed “Search index maintenance.” The task detail reported a change, which appeared to mean the live transcript had invalidated indexing.

## Evidence and cause chain

- Inspected a private copy of `tasks.jsonl`, without changing the active library. Source size and modification time were unchanged across the copy. No meeting text or identifiers were copied into repository fixtures.
- An automatic search task was queued, started, and then paused with manual recovery about one second later. Its exact saved error was “This task changed outside the app. Resume to continue.” This is the external task-journal recovery path, not the transcript fingerprint mismatch path.
- `reloadExternalManagedTasksCommand` observes a changed journal, rebuilds its disposable index, compares task execution intents, and pauses changed active requests when this process has no managed operations. That pause requires a deliberate Resume to avoid submitting externally changed work silently.
- The task was later stopped and removed. The journal does not record writer identity; the evidence cannot identify the external writer or prove whether another app instance, a file rewrite, or another source caused the change.
- The banner independently combined an attention count with an activity summary. The maintenance text was not an explanation of the alert. The accompanying task-visibility change removes this unrelated activity text from the attention banner.
- Normal saved-content changes follow a different path: recording start suspends indexing, checkpoint notifications defer scanning, and the scan resumes after finalization. A search source fingerprint mismatch already cancels the stale task without attention and requests a fresh scan.

## Implemented solution

Clarified the recovery message to “The saved task request changed outside this app. Resume to continue.” Added synthetic regression coverage for saved-content updates during capture and finalization, and for externally changed queued and running search requests.

## Reasoning

Kept the external-request safeguard. Automatically cancelling and resubmitting an externally running request could duplicate another process’s work. The available evidence does not justify changing indexing scheduling or hiding genuine external task changes.

## Technical debt

Retained: the task journal has no writer identity or execution lease. This prevents attribution of historical external changes and prevents safe automatic takeover of another writer’s active task. A future ownership protocol should identify writers and establish an expiring lease before automatic recovery across processes. No new compatibility bridge or schema debt was introduced.

## Validation

Combined release regression run passed: 61 tests in 7 suites, including all recording-search alert cases. The first test build rejected a fixture assignment to the private recording-start setter; the fixture was corrected without weakening production access controls. Final isolated release build and scoped formatting passed. Two existing missing Command Line Tools linker-search-path warnings remain; no deprecated API warnings appeared. The active recording was not stopped, relaunched, or edited. The historical external writer cannot be reproduced from the saved journal alone. The recording-start gate was reviewed in code but not exercised: its private setter remains protected, and the test does not invoke real capture.
