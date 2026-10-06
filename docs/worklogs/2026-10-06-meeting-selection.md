---
title: Open selected meetings before loading their content
date: 2026-10-06
status: complete
scope: swift-macos-library
---

# Open selected meetings before loading their content

## Problem

A single click selected a library row but left “No Meeting Selected” in the detail pane when the meeting was absent from the content cache. `LibraryView` required a cached payload before mounting `MeetingDetailView`, preventing that view's loading task from running. Double-click playback happened to load the content first.

## Implemented solution

Create `MeetingDetailView` and show its content tabs whenever Meetings has a selected ID. The detail view continues to own its loading, failure, retry, and loaded-content states. Cache population remains a consequence of loading. Native selection and playback actions are unchanged.

`MeetingSelectionTests` mounts the production library with two synthetic disk-backed meetings absent from the cache, selects each through the native table, and checks that content loads without starting or assigning playback.

## Reasoning

The existing detail loader already implements the required behavior. Removing the cache prerequisite restores that responsibility without another loading task, eager library hydration, or a special click handler.

Before editing, inspected the supplied failure screenshot and captured the existing isolated Preview. Reproduced the cold-cache failure with its pagination fixture: a highlighted row still showed “No Meeting Selected.” The intended layout retains the list and detail pane; selecting a row immediately mounts the existing detail loading state, followed by the selected content or recovery controls.

## Technical debt

None.

## Validation

Regression builds used the isolated snapshot at `tmp/meeting-selection-fix`; the running development and other Preview bundles were preserved. Baseline UI reproduction used the copied Preview revision `0933d7b-clsp-final`, a separate bundle identifier, and `GdaySyntheticPagination=true`, with synthetic audio and silent playback. macOS 26.6.2; Swift 6.4; SDK 27.0. Screenshots were inspected through the computer-use capture results.

The new regression failed on the original implementation for both uncached selections; its fixture, indexing, and native table mounting checks passed. With the fix, all eight tests in `MeetingSelectionTests`, `MeetingPrefetchTests`, and `WorkspaceStateTests` passed. Formatting, strict lint, and whitespace checks passed.

The installed Command Line Tools required the explicit Swift Testing plugin flag already used by `test-macos.sh`; a first patched run failed macro discovery, and the rerun passed with that flag. Existing linker warnings remain for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search directories. These are toolchain configuration warnings; repair or update the selected toolchain and rerun validation. No API deprecation warning was reported.

The coordinated toolbar snapshot at `tmp/toolbar-review/checkout` includes both selection changes. Its release build, linked-platform check (macOS 26 minimum, SDK 27), bundle validation, and signing passed; see `tmp/toolbar-review/final-release-build.log`. `Selection Preview.app` used revision `toolbar-and-selection-final`, built October 6 at 05:54 UTC, with pagination and chrome-only flags. The latter hides the Preview banner while retaining synthetic content and silent playback.

Final Preview checks passed: a single click opened an uncached meeting's transcript; Down opened the next uncached meeting; double-click started silent playback; selecting another meeting retained the playing audio. Screenshots at 1200-point and 900-point widths showed the selected detail and content tabs. Expanding the sidebar at the narrow width preserved the detail, and selecting another cold row opened it. System appearance resolved to light. Dark appearance, VoiceOver, failed-file retry, real capture, and audible playback were not exercised by this selection check. No push was requested, so hosted CI was not run.
