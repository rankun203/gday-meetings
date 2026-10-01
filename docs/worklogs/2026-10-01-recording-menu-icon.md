---
title: Recording menu-bar icon
date: 2026-10-01
status: validated
scope: swift-app-menu-bar
---

# Problem

The supplied screenshot shows a round center in the recording menu-bar icon, although its primary action is Stop Recording.

# Implemented solution

Use the native `stop.circle.fill` symbol while recording. The intended appearance is a square stop mark inside the circle. The menu still exposes Stop Recording and Show App.

# Reasoning

The square matches the stop action and the existing menu item's symbol. This is a symbol-only change with no recording lifecycle changes.

# Technical debt

None.

# Validation

Before-edit screenshot inspected. Release and isolated synthetic-recording visual checks are pending. The active recording must not be stopped for validation.

## Combined validation

Combined validation passed: 517 tests in 96 suites (66.864 seconds), strict Swift formatting/lint, and isolated `make build-macos` (54.65 seconds), including signing. The build retained the documented missing Command Line Tools search-path linker warnings. No new API deprecation warning appeared. The real recording and running app bundle were preserved.

The isolated app launched with a synthetic recording. Menu-bar capture through SystemUIServer timed out; the after-state menu-bar icon could not be visually verified. Source and release compilation confirm `stop.circle.fill`. No recording control was invoked.
