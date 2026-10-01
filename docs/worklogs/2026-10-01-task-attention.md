---
title: Task attention and recovery controls
date: 2026-10-01
status: validated
scope: swift-app-ui
---

# Task attention and recovery controls

## Problem

The supplied Tasks screenshot showed small, secondary-colored attention counts in the status bar. Failed tasks shared the same visual weight as completed tasks, and their recovery actions were difficult to identify.

## Implemented solution

`TaskQueueView.swift` places failed tasks in a **Needs Attention** section before other tasks, preserving newest-first order within each section. Failed cards use a filled attention symbol, a stronger status label, and primary-colored error text. Available **Retry**, **Resume**, or **Restart** buttons appear first with the native prominent button style. Their availability and behavior remain controlled by the existing task recovery APIs.

The status bar shows an accent-colored attention symbol and count with a native **Review Task** or **Review N Tasks** button. Running and queued counts remain visible alongside it. Recording controls are unchanged.

`UIPreview.swift` accepts the `GdaySyntheticTasks` bundle flag in addition to `--synthetic-tasks`, allowing a separate validation app to launch its existing synthetic task fixtures without command-line arguments. These include a retryable summary, an expired transcription, active tasks, and a completed task.

## Reasoning

Explicit text and a filled symbol make attention visible without relying on color. A standard button provides keyboard, accessibility, hover, and pressed behavior. Grouping failures first makes the review action lead directly to relevant tasks. Backend recovery messages remain authoritative; the UI does not infer recovery from HTTP status text.

## Technical debt

None.

## Validation

- Inspected the user-provided screenshot before editing and described the intended hierarchy and controls.
- Reviewed new and surrounding wording against `docs/writing.md`.
- `make format-macos` and `make lint-macos` passed.
- Release validation, screenshots, checked interactions, and remaining limits are recorded below.
- No real recording, saved request, or running preview was changed during this UI sub-task.

## Combined validation

Combined validation passed: 517 tests in 96 suites (66.864 seconds), strict Swift formatting/lint, and isolated `make build-macos` (54.65 seconds), including signing. The build retained the documented missing Command Line Tools search-path linker warnings. No new API deprecation warning appeared. The real recording and running app bundle were preserved.

After-change screenshots in System (light) and Dark showed failed tasks first, stronger error text, the attention count, and the review button alongside the synthetic recording strip. **Review 2 Tasks** navigated to Tasks. Synthetic **Retry** changed the count to one; **Restart** removed the remaining attention state and restored the activity-only bar. No real provider request was submitted. Keyboard Tab navigation was exercised, but recovery-button keyboard activation, Dismiss, narrow windows, and explicit Light appearance were not checked. Screenshots captured inactive-window button styling, so active-window tint was not established.

Commit `3ceb78f` was pushed to `master`. [Release CI](https://github.com/rankun203/meeting-notes/actions/runs/36816224156) passed on macOS 15, 26, and 27.
