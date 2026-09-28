---
title: Reuse the main Meetings window
date: 2026-09-28
status: validating
scope: swift-window-lifecycle
---

# Reuse the main Meetings window

## Problem

The supplied menu-bar screenshot shows repeated Show App actions opening duplicate meeting windows. Each window also mounts another copy of the library and its observers.

## Implemented solution

The main scene uses SwiftUI Window rather than WindowGroup. Existing openWindow actions now target a single scene instance, including Show App and recording setup. The menu label uses consistent title case.

Independent review also found that Command-N needed a visible window to host recording setup. The command now opens the singleton scene before presenting the sheet, including after the main window was closed.

## Reasoning

The app has one shared library, recording session, and playback transport. A singleton scene expresses the requested behavior without tracking AppKit windows by title. Apple's [Window documentation](https://developer.apple.com/documentation/swiftui/window) describes a single unique window and lists availability from macOS 13, below this app's macOS 14.2 minimum.

## Validation

Baseline inspected from the user's screenshot. Consolidated build and repeated Show App, close/reopen, and recording setup checks are pending.

The consolidated suite passed all 418 tests in 83 suites; formatting and diff checks passed. Visual window lifecycle checks remain pending the rebuilt Preview.

Preview lifecycle validation passed: closing the main window and pressing Command-N reopened Meetings and presented New Recording. Cancel returned to the same singleton scene. The Window menu's Meetings action also reused that scene. Direct repeated menu-bar Show App clicks remain unverified by UI automation; the action targets the same single Window scene.

Final consolidated validation passed all 421 tests in 84 suites, formatting, lint, and diff checks. The signed release Preview was rebuilt and reopened. Existing Command Line Tools linker warnings about missing SDK search directories remain; no new deprecation warning was reported. The installed regular app was not replaced during Preview validation.

## Technical debt

None.
