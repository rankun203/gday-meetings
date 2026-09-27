---
title: Managed transcription and summary tasks
date: 2026-09-27
status: implemented
scope: swift-background-tasks
---

## Problem

The app already scoped background jobs by meeting, but only displayed the most recent task in the status bar. RunPod and website polling stopped after 150 two-second waits and raised a modal telling the user to resume later. This made work waiting at the provider appear stalled and offered no central queue controls.

## Design before implementation

Inspected both supplied screenshots: Meetings, People, and Tags occupy the sidebar; a bottom spinner describes one task and optionally another task count; the pending-provider notice interrupts the meeting with a modal. Add a Tasks sidebar destination with a full-width panel for active, queued, attention, and recent tasks. Rows show meeting, operation, provider, progress, and supported controls. A clickable bottom status bar summarizes counts and opens Tasks. Keep recording and playback surfaces available.

## Implemented solution

Added a scheduler with two transcription slots and one independent summary slot. `ManagedTasks.swift` saves queued intents and outcomes in `managed-tasks.json` before starting requests. Tasks exposes running, queued, attention, and recent work, with priority, removal, local cancellation, recovery, and dismissal controls. The sidebar and persistent status summary open the panel. Other background operations remain visible there.

RunPod and website jobs poll continuously with cancellable two-second waits, retaining their original remote IDs. Background provider errors appear on task rows. Reopening the app restores interrupted tasks for manual recovery without contacting providers. Automatic summaries use the latest input when starting and combine transcript changes received while queued; a newer transcript received during processing schedules another summary.

## Reasoning

Accepted job IDs must remain attached to their original provider. Stopping local waiting is distinct from cancelling remote processing. Recovery must never silently repeat an ambiguous paid submission. At the user's request, Tasks has no backward-compatibility bridge: only records saved in its own format appear after reopening. Removed startup reconstruction of task rows from pre-queue transcription attempts. Existing attempt data remains available to the meeting's explicit Resume Transcription action.

## Technical debt

The summary API has no durable remote job ID. Retrying an interrupted summary can repeat a request already processed by the provider; recovery is explicit and the row explains this limitation. A future adapter with durable job IDs could resume these requests. Task history has no automatic retention limit and is dismissed manually; a future retention policy should bound old terminal records for long-lived libraries. Task decoding intentionally requires the current format; no compatibility migration is planned.

## Validation

Full Swift suite passed: 332 tests across 68 suites (`/tmp/gday-queue-full-fixed.log`). Tests cover concurrent meetings, duplicate prevention, queued ordering/removal, 156 polls beyond the former cutoff, Stop Waiting and GET-only resume, ambiguous-submission protection, restart recovery without network work, and disabled automatic-summary scheduling. Independent review found and resolved a scheduler reentrancy issue. Loopback tests initially omitted a required synthetic API key; corrected the fixture. Two existing main-actor test waits now tolerate unrelated synchronous test stalls while retaining bounded waits and unchanged response assertions.

Preview build succeeded (`/tmp/gday-queue-build.log`); formatting, lint, and diff whitespace checks passed. Existing Command Line Tools missing-library/framework-search-path linker warnings remain, as documented in the September 25 toolchain worklog. No new deprecations were reported.

Post-change screenshot and interaction validation remain unverified: the computer-use service returned `cgWindowNotFound` for the isolated Preview and the installed app, including after Preview relaunch and tool reset. The explicit synthetic task fixture is available for follow-up visual checks. Production jobs and recordings were not modified, and the installed application was not replaced.

Before commit, removed the task compatibility bridge as requested. A regression test confirms that an existing transcription attempt creates no task record on startup. The full suite then passed 333 tests in 68 suites (`/tmp/gday-queue-final-tests.log`), with formatting, lint, and diff checks passing.
