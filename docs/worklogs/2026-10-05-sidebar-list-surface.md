---
title: Meeting list background
date: 2026-10-05
status: implemented
scope: swift-library-ui
---

## Problem

The meeting list had an explicit text-reading background beside the native sidebar. This added a dark rectangular surface across the list column, making the sidebar-to-list boundary more prominent.

## Evidence and design

Inspected the supplied screenshot and captured the expanded sidebar in the isolated synthetic UI Preview before editing. Preview identified its build as `40e64af-summary-instructions`; it was launched from `apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app` on macOS 26.6.2 (25G83). This was an earlier build, not the current working tree. The before capture appears in this task's computer-use output.

The native meeting table and scroll view already draw transparent backgrounds. Remove the extra reading fill from the Meetings directory column and let the native split view supply its background. Keep the sidebar's system material, meeting selection, table reuse, layout, and detail reading surface. Native sidebar material may still differ from the content column; do not imitate it with another blur or glass layer.

## Implemented solution

Removed the meeting list's explicit `AppTheme.readingBackground` in `LibraryView.swift`. The selected meeting detail retains its reading background. There are no new controls or wording changes.

## Reasoning

The list selects content; it does not need the same explicit reading surface as the transcript and notes. Removing the extra layer gives the native navigation container ownership of this surface without changing native row selection, scroll insets, or sidebar appearance.

## Technical debt

None.

## Validation

Before capture completed with synthetic data. Parent completed an integrated release build, then the rebuilt Preview labeled `40e64af-responsiveness-ui` was inspected in dark and light appearances with the sidebar expanded and a meeting selected. The list now inherits the window surface; the selected row and detail remain readable. The native sidebar retains its distinct glass material and outline. This change removes the app's extra reading fill; it does not force identical pixels across system materials. Screenshots are in the task's computer-use output. No isolated tests were added for removing a background modifier. The older Preview's toolbar appearance is a separate issue and is outside this change.

Inactive dark appearance was captured before selecting a meeting; the active selected state was checked in both appearances. Reduced transparency and increased contrast were not toggled during this review. Native material accessibility behavior is unchanged.
