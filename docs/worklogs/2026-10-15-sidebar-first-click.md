---
title: Navigate from the sidebar on the first click
date: 2026-10-15
status: implemented
scope: macos-library-navigation
---

## Problem

Clicking a sidebar destination while working in the content pane could focus the sidebar without navigating. The production sidebar reproduced this in an isolated SwiftUI window with a focused notes editor and a 20 Hz synthetic content refresh. During pointer tracking, AppKit had selected Tasks but the binding still held Meetings. An unrelated representable update restored Meetings before AppKit completed selection.

## Implemented solution

`NativeLibrarySidebar.Coordinator` remembers the last synchronized model selection. It applies incoming selection only when that model value changes. Completed native selection updates the snapshot and publishes navigation once. Genuine programmatic navigation and clearing selection for Search still apply.

The regression covers repeated refreshes during pending selection, final publication, an immediate programmatic return to the previous destination, another destination, and clearing selection. Existing tests cover keyboard notification handling, duplicate notifications, and preserving text focus during programmatic updates.

## Reasoning

Before editing, inspected the user's screenshot and captured the isolated production sidebar with content focus. The intended design preserves the existing layout, controls, native selection appearance, and keyboard behavior. One click transfers focus and navigates after AppKit completes selection. No timing delay, early navigation, mouse interception, or forced focus is needed: the problem was redundant model-to-view synchronization.

## Technical debt

None.

## Validation

- Baseline isolated regression failed because a content refresh reset Tasks to Meetings and prevented navigation. A real one-second pointer press reproduced the same failure. The trace recorded an update with bound Meetings and native selected row Tasks before the row reverted.
- With the change, the same focused editor, 20 Hz refresh, and one-second Tasks click navigated on the first click. Captured and inspected the resulting Tasks selection and content. Down Arrow selected Agents; focusing the editor and an ordinary pointer click returned directly to Meetings.
- The probe uses the production sidebar source in `tmp/sidebar-first-click-20261015/Sidebar First Click.app`, with synthetic notes and no audio, user library, credentials, or services. Evidence was captured through Computer Use. Runtime: macOS 26.6.2; Swift 6.4; source revision `e48768e` plus this working change. The existing app and playback were untouched.
- All four focused sidebar interaction and focus tests passed in an isolated package using production source. Logs: `/tmp/sidebar-first-click-baseline-tests.log` and `/tmp/sidebar-first-click-fixed-tests.log`. `make format-macos`, scoped Swift lint, and `git diff --check` passed. The combined final run passed 11 tests in four suites, including these sidebar tests and actual Apple speech-engine recognition. The isolated `make build-macos` release build passed, including bundle validation and signing. The isolated test build retains Command Line Tools linker warnings about missing framework and library search paths and restricted AppKit XPC diagnostics.
- Visual checks covered light appearance in the 900-by-550-point isolated window. Full production Preview, dark appearance, inactive-window activation, and continuous playback remain outside this probe's coverage.
