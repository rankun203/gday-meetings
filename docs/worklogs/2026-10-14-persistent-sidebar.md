---
title: Keep the library sidebar mounted during navigation
date: 2026-10-14
status: complete
scope: macos-library-navigation
---

## Problem

Switching between Meetings, People, or Tags and Tasks or Agents replaced the entire navigation split, including the sidebar. The clicked selection briefly lost focus while a deferred transfer focused the replacement table. Baseline Preview screenshots and accessibility inspection confirmed Tasks → Meetings replaced both the outer split and sidebar table.

## Implemented solution

`LibraryView` now owns one two-column `NavigationSplitView` for the sidebar and workspace. Only the workspace switches destinations. Meetings, People, and Tags use a native `HSplitView` for their resizable directory and detail, preserving the existing width limits. Tasks, Agents, and Search retain their own content. Initial sidebar visibility uses `.detailOnly` directly.

Removed the cross-layout focus request, table subclass, destination layout classification, and visibility conversion. The native sidebar reveal bridge no longer waits for a destination-specific column count. Selection updates use the same native table without requesting focus. The diagnostic sidebar toggle now calls the same native action as the toolbar; its former SwiftUI visibility mutation exercised a different path and could widen the window. Removed its unused SwiftUI completion callback; the performance fixture continues measuring frame pacing and settled visibility.

## Reasoning

Keeping the navigation container stable removes the cause of the flash and lets AppKit retain selection and focus. Existing workspace state continues to own selections and scroll positions. A `GeometryReader` resolves the workspace safe rectangle once before sizing its native split. Without that boundary, nested hosting views counted the 208-point sidebar safe area twice and increased the minimum width from 887 to 1,095 points. Explicit column minima and a native collapse policy did not fix that duplication; both trials were removed. No delayed focus correction or animation suppression replaces the removed workaround.

## Technical debt

Retained the existing per-window native sidebar-action bridge. SwiftUI visibility changes previously widened narrow windows, while the native toggle reallocated available space. The bridge still discovers the public AppKit split controller in the window view tree and defers a pending reveal until mounting finishes. Its consequence is dependence on SwiftUI's AppKit hierarchy; regression tests cover width and container identity. Replace this bridge when a supported SwiftUI reveal action provides equivalent width behavior. No storage migration or new schema debt is introduced.

## Validation

- Baseline: parent captured and inspected the isolated synthetic Preview before edits; switching Tasks → Meetings replaced the split and sidebar accessibility elements.
- Updated integration regression requires the same sidebar table and outer controller across Tasks, Agents, People, Tags, and Meetings, with selection and keyboard focus retained. It also covers leaving Meetings while the sidebar is collapsed and checks unchanged window width.
- Programmatic sidebar-selection regression verifies an active text field keeps focus, including clearing selection for Search.
- The final combined run passed 82 of 83 tests. The remaining divider test measured the native hosting safe-area inset as directory content. Corrected that measurement, then reran the test successfully (`/tmp/persistent-sidebar-divider-final.log`). Across both runs, all 83 relevant tests passed, including 75 task regressions and sidebar identity, focus, 900- and 1,200-point bounds, divider resizing, rapid reversal, scrolling, and repeated animated and reduced-motion toggles.
- Formatting lint and `git diff --check` passed. The isolated `make build-macos` release build passed with matching production sources (`/tmp/sidebar-final-release.log`). Existing Command Line Tools linker search-path warnings remain; no source deprecation warnings were reported.
- Captured and inspected the changed synthetic Preview. Mouse and keyboard navigation across Meetings, People, Tags, Tasks, and Agents retained the sidebar. Divider resizing, sidebar reveal through Review Tasks, and selected-meeting toolbar controls worked. Search and return to People retained the same sidebar; semantic results could not be validated because the preview lacked local model assets and displayed a missing `LICENSE` error. No model download or provider work was started.
- Visual checks covered light appearance at the current window size. Narrow widths were checked by native integration tests. Dark appearance and continuous frame-by-frame flicker were not measured. Screenshots were inspected through computer use and were not added to the repository.
- The production bundle is `tmp/production-20261014-persistent-sidebar/Gday Meetings.app`. CI matrix status is checked after pushing and reported with the delivery.
