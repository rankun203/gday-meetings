---
title: Stable task updates and missing-meeting history
date: 2026-10-14
status: complete
scope: macos-tasks
---

## Problem

Search maintenance triggered unrelated task-page refreshes. Each refresh temporarily removed the count footer, forcing the native table to reload and making unchanged alert rows flash. Automatic indexing was excluded from All Tasks. Saved requests for deleted meetings became repeated alerts.

## Implemented solution

- Keep the count footer, loaded rows, and selection during background page loads. Reuse the native table's existing row-level updates, and avoid publishing unchanged session rows or selection. Update selected task details directly when cached progress changes.
- Track journal revisions by task scope, including both the previous and new record when a task enters or leaves a filter. Observe only voice jobs matching the current scope. Maintenance updates therefore leave an unchanged Needs Attention page alone.
- Include automatic indexing in All Tasks and retain Search Index Maintenance. Active and History retain their existing exclusions for automatic indexing.
- Activate maintenance status when work is admitted and retain it across discovery gaps until the final scan finishes without queued, running, or paused maintenance. A scan that finds no work does not display maintenance status.
- Keep confirmed missing-meeting requests as cancelled records without attention or retry. App deletion records a specific deletion result. A missing or unreadable library remains distinguishable from a confirmed missing meeting.
- Exclude meetings being deleted from task admission and recheck after awaited journal writes. Resume admission after deletion finishes, including a failed deletion. A late worker completion reads the durable task record and preserves a terminal cancellation; an already committed result receipt still takes precedence.
- Add a finite, opt-in preview (`--synthetic-tasks --synthetic-task-refresh`) that changes synthetic maintenance progress for 30 seconds while alert records remain unchanged.

## Reasoning

Preserve the existing two-pane layout and controls. The supplied screenshot and a captured running-app baseline show that the problem is update behavior, not information placement. Scoped invalidation avoids unrelated disk queries; retaining the footer prevents full native reloads. Maintenance discovery does not know a reliable total in advance, so the status stays stable without a misleading percentage. Existing cancellation records can express a deleted source without changing the storage schema.

## Technical debt

None. No data migration, timer-based status suppression, or alternate task store was added.

## Validation

Added regression coverage for scoped invalidation, maintenance status across gaps and completion, and the native table retaining its footer and selection while reloading only a changed row. The native test uses the same footer-presentation helper as Tasks. Missing-meeting tests cover confirmed absence and unavailable or unreadable input. All fixtures use synthetic data.

Parent review checked filter entry and exit, selected-detail updates, cancellation recovery, bounded deletion updates, and unavailable-library handling. Regression coverage includes native table refreshes, task paging and recovery, search rebuilds, and notes indexing boundaries. Formatting lint and `git diff --check` passed.

Additional independent review found a queued-task admission race during deletion. Added deterministic regressions for excluded admission and late failure after durable cancellation, with and without a committed result receipt. All 75 task tests passed in the final combined run (`/tmp/sidebar-final-regressions.log`); that run's only failure was a separate sidebar divider measurement test, which passed after correcting its safe-area measurement. The final isolated release build also passed (`/tmp/sidebar-final-release.log`).

`make build-macos` passed in the isolated `tmp/task-stability-validation-20261014` checkout with matching source files. Packaging verified macOS 26.0 minimum, SDK 27.0, the app plist, and the code signature. The production bundle is `tmp/production-20261014-persistent-sidebar/Gday Meetings.app`. The existing Command Line Tools linker warnings about missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths remain; no source deprecation warnings were reported.

Captured the existing Tasks screen and compared it with the changed release in an isolated, visibly marked synthetic Preview. During the maintenance simulation, Needs Attention retained its four rows, selection, and count. After completion, only the maintenance status disappeared. All Tasks showed both indexing records; Search Index Maintenance showed the same two records. Dismissing a synthetic alert reduced the count to three and selected the next alert. No provider work or recording ran, and the user's library was not changed. Captures were inspected through computer use; no private screenshots were added to the repository. Visual validation covered light appearance at the current window size, not dark appearance or a continuous frame-by-frame flicker measurement. Native-table regression tests additionally verify that background refresh performs no full reload.

CI matrix status is checked after pushing and reported with the delivery.
