---
title: Task filter menu and empty states
date: 2026-10-13
status: implemented-with-validation-limits
scope: macos-task-queue
---

# Task filter menu and empty states

## Problem

The supplied open-menu screenshot shows an unnecessary Show Tasks submenu. Resetting the filter requires navigating that submenu, and the empty list gives no recovery action. Dismiss All Alerts takes space even when disabled.

## Implemented solution

TaskQueueView uses an inline native Picker inside its Menu so the choices appear at the first level. All Tasks remains the first and default scope. The header keeps one row and shows Dismiss Alerts only in Needs Attention while alerts remain. Empty filters describe the current scope and offer Show All Tasks when that scope contains rows. No task history shows “No tasks yet” without a reset button.

## Reasoning

Use the native menu's tracking and keyboard behavior rather than replacing it with custom pointer gestures. Apple's [inline picker style](https://developer.apple.com/documentation/swiftui/pickerstyle/inline) presents options in their current container. Reset belongs in the empty list area, preserving header width. Complete indexed counts, cached tasks, and voice jobs distinguish empty history from an empty filter. Existing automatic search-maintenance separation is preserved.

## Technical debt

None.

## Validation

Before editing, inspected the supplied screenshot of the nested filter menu and the earlier empty Tasks screenshot. Intended design: one header row, one menu level, native checked selection, and an empty-list recovery button. Formatting and diff whitespace checks passed. No user meeting data was copied into fixtures or documentation.

The coordinated isolated release build passed. Release-configured tests passed: 16 tests across LibrarySidebarTests, NativeLibrarySidebarFocusTests, NativeLibrarySidebarInteractionTests, and TaskQueueSessionTests. The test linker reported existing Command Line Tools missing-search-path warnings; no deprecation warnings were reported.

Runtime checks used the production release executable, packaged as `tmp/sidebar-regression-20261013/Filter Validation.app`, with `GdayUIPreview=true`, `GdaySyntheticTasks=true`, and revision label `7440a8f-sidebar-filter-fix`. The coordinator confirmed the two changed Swift source files matched the release checkout. The second bundle, `Empty Filter Validation.app`, used the same binary with synthetic tasks disabled. Both had separate validation bundle identifiers. The environment was macOS 26.6.2 (25G83), Apple Swift 6.4, ARM64; validation ran October 13 around 19:21–19:27 local time. The copied release bundle did not contain a Preview build-time metadata field.

Captured and inspected the production UI through computer-use screenshots at 2400 × 1600 pixels (1200 × 800 points), with the fixed 340-point task column:

- All seven filters appeared at the first menu level, with a native checkmark beside the selected scope, in light and dark appearance.
- Ordinary selection worked. A one-second held click opened the menu. Arrow keys and Return selected Active, and Escape closed the menu without changing scope.
- Dismiss Alerts cleared four synthetic alerts, hid the header button, cleared the detail, and displayed “No tasks need attention” with Show All Tasks. Reset restored all twelve ordinary task rows.
- The header remained on one row with both Needs Attention and Dismiss Alerts visible.
- A separate no-task Preview showed “No tasks yet” in both All Tasks and Needs Attention, without a reset or dismissal action.
- Full-window pointer navigation through Tasks, Meetings, and Tasks remained selected. A held Tasks click also succeeded. Down Arrow after arriving at Tasks selected Agents, confirming keyboard focus survived the transition.

Limits: press-drag-release could not be established. The computer-use drag call opened the menu but left it open, with the pointer capture at the start position; the coordinator observed the same drag limitation outside menus. No custom gesture workaround was added. A physical pointer check remains necessary for release-over-item selection and pointer-only hover. The fixed task-column width was inspected, but resizing the complete window to its 900-point minimum, VoiceOver speech, and increased-contrast/reduced-transparency settings were not exercised. Both validation copies were quit after testing; the user's app remained untouched.
