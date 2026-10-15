---
title: Task progress and remaining-time estimates
date: 2026-10-15
status: complete
updated: 2026-10-16
scope: macos-task-progress
---

## Problem

Long-running tasks expose text status without consistently showing measured work or estimated remaining time. Indexing and voice preparation already count work, but Tasks does not present those counts as progress bars.

## Implemented solution

The UI uses one native linear progress component in managed task details, voice preparation, and transient background operations. List rows show measured percentages and available estimates without changing row height. Operations without estimates show elapsed phase time. Synthetic Preview includes measured indexing, diarization, provider waiting, generation, and saving states.

Shared snapshots preserve current progress across history reads and checkpoint writes. Attempt identifiers reject late callbacks. A disposable local cache learns from successfully saved processing results. The [core worklog](2026-10-15-task-progress-core.md), [audio worklog](2026-10-15-audio-task-progress.md), and [other-operation worklog](2026-10-15-operation-progress.md) record sampling and phase boundaries.

## Reasoning

The current installed Tasks screen and the supplied running-task screenshot were inspected before UI changes. The running state shows a spinner and text, with different status text in the list and detail. The intended design preserves the two-pane layout and task actions, adds a linear bar beneath the phase, and places a concise remaining-time estimate below it. Unknown totals remain indeterminate. Completion follows saved results, never elapsed predicted time. Terminal tasks do not show an active bar or stale estimate.

## Technical debt

None. Operations without provider totals retain indeterminate progress; measured percentages describe the current phase rather than whole-task completion. Archive uploads report bytes only after each file finishes because the current transfer interface has no within-file callback. Whole-library rebuilds retain meeting counts without a time estimate because meeting workloads differ.

## Validation

Three implementation agents reviewed each other's work; parent review inspected the complete task-only diff. Review fixes covered stale history and checkpoint snapshots, callback ordering, successful-result-only cache updates, sleep-safe clocks, and transient voice estimates. Voice estimates no longer add recovery writes or repeatedly scan the full example inventory.

The integrated working tree passed 218 tests across 49 suites covering progress, task paging, native task list updates, provider states, indexing, voice operations, imports, recording pipelines, and chat persistence. Formatting, lint, and whitespace checks passed. The final task-only snapshot passed 32 focused tests across 6 suites, including the transient voice estimate regression, and `make build-macos` completed successfully. The snapshot also passed lint. No source or deprecation warnings were emitted.

The initial working tree contained unrelated changes. A private baseline and three-way file merges isolate this task's commit while preserving those changes. Release validation uses a separate snapshot of HEAD plus the task changes, including the existing HEAD diarization and recording-save paths. No real recordings or provider requests were used for UI validation. Screenshots of the isolated synthetic preview confirmed measured indexing progress in light and dark appearance, matching list and detail estimates, indeterminate provider waiting, and completed tasks without active bars. Keyboard selection remained stable; queued and paused tasks cleared their estimates. The inspected window was 1200 by 800 points. Narrow-window layouts and live provider processing were not exercised. The installed app was not replaced.

The validation host uses macOS 26.6.2, Swift 6.4, and SDK 27.0; the deployment minimum remains macOS 26. Existing Command Line Tools linker warnings reference missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths. These are toolchain packaging warnings, not deprecated source APIs. Follow up by validating with a complete Xcode toolchain when available; this task does not suppress the warnings.
