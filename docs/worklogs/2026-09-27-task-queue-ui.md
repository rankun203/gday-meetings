---
title: Tasks navigation and queue controls
date: 2026-09-27
status: implemented
scope: swift-app-task-ui
---

## Problem

Background work appeared only as a spinner and the latest progress message. People could not inspect the queue, manage individual tasks, or return to a task's meeting from that status.

## Design before implementation

The coordinator inspected the supplied screenshots showing Meetings, People, and Tags in the sidebar, a bottom progress strip, and a modal transcription timeout. Add Tasks to the sidebar and make the bottom status a native button that opens Tasks. Use the full content width for grouped Running, Queued, Needs Attention, and Recent sections. Keep the recording and playback strips visible. Each row identifies its meeting, operation, provider, progress, and supported actions. Actions stack at narrow widths.

## Implemented solution

`LibraryView.swift` adds the Tasks destination and replaces the transient progress strip with a persistent queue status button. `TaskQueueView.swift` groups managed tasks by state, shows other active background work, and exposes Open Meeting, Run Next, Remove from Queue, Stop Waiting, Retry or Resume, and Dismiss when supported. Counts exclude duplicate background registrations. Running rows explain that stopping local waiting may leave provider processing active.

`UIPreview.swift` adds the explicit `--synthetic-tasks` fixture with running, queued, failed, and completed tasks. Synthetic actions use the backend's local Preview behavior and never submit provider work. Ordinary Preview launches do not add fake tasks. The README and UI Preview guide document concurrency limits, queue controls, retained task records, and manual recovery after reopening.

## Reasoning

A full-width task panel keeps meeting and recovery details readable without another narrow selection column. Native buttons retain keyboard access, and adaptive action layout supports smaller windows. The status remains available when the queue is idle so Tasks is reachable with the sidebar collapsed.

## Validation

Reviewed added wording against the writing guide. Formatting, lint, Preview build, and all 332 tests across 68 suites passed. Existing Command Line Tools linker-search-path warnings remain. Post-change screenshots, keyboard navigation, status-button navigation, and adaptive layout are not visually verified: the computer-use service returned `cgWindowNotFound` for both Preview and the installed app after relaunch/reset attempts. The `--synthetic-tasks` fixture is ready for those checks when window inspection is available. Production recordings and jobs were preserved.

## Technical debt

The backend now persists queued intents and history in `managed-tasks.json`. Interrupted work appears under Needs Attention after reopening, requiring explicit Resume or Retry. Summary providers have no durable remote job identifier, so retry starts another completion request rather than recovering its previous result. This preserves the existing provider contract and avoids automatic duplicate submissions. Durable summary recovery requires a provider-supported job or idempotency contract before the UI can offer Resume for summaries.
