---
title: Open active transcription task from its meeting
date: 2026-09-27
status: complete
scope: swift-task-navigation
---

## Problem and design

The supplied screenshot shows a disabled Resume Transcription button even though the meeting has a running transcription task. Replace the action with an enabled “Transcribing…” button, or “Queued · Show Task” for queued work. Open Tasks, scroll to the matching row, and outline it with the accent color. Keep inactive transcription actions unchanged.

## Implemented solution

The shared transcription action reads the matching active task before considering pending attempts. A window-local environment action passes its stable ID to LibraryView. TaskQueueView uses that ID for scroll positioning and highlighting. Sidebar and status-bar navigation clear the targeted selection. This action does not submit or resume provider work.

## Reasoning

The managed task is the source of truth for queued/running state. Window-local navigation also works for meeting details opened from People or Tags without sharing selection between app windows.

## Technical debt

None added.

## Validation

All 365 tests in 73 suites passed. Formatting, lint, Preview build, and diff checks passed. The build retains the previously documented Command Line Tools linker search-path warnings.

In the isolated synthetic Preview, verified the enabled task navigation button before shortening its label. Clicking it selected Tasks, scrolled the matching running transcription into the center of the viewport, and outlined its card in the accent color. Captured and inspected the resulting screenshot against the design. The People/Tags sheet routing was reviewed and compiled but not exercised interactively. Production recordings and provider jobs were preserved.

The running label was shortened to “Transcribing…” after the user’s screenshot showed truncation beside Transcript History. The task navigation and explanatory tooltip stay the same.

Rebuilt Preview after shortening the label and captured the meeting screen. “Transcribing…” fits in full beside Transcript History. Lint and diff checks passed.
