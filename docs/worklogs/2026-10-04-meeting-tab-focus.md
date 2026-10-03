---
title: Meeting tab pointer and keyboard focus
date: 2026-10-04
status: complete
scope: swift-app-ui
---

# Meeting tab pointer and keyboard focus

## Problem and design

Clicking Transcript, Notes, Summary, or Data Privacy explicitly assigned keyboard focus, leaving a blue focus border around the selected tab. An isolated synthetic Preview reproduced the issue before editing. Keep the existing capsule layout and selected background. Pointer selection should clear the tab group's keyboard focus; keyboard navigation and activation should retain visible focus.

## Implemented solution

`MeetingContentTabs` now changes selection in its native Button action without assigning focus. A simultaneous tap gesture clears only this group's focus after a pointer click, including focus left by earlier keyboard navigation. Arrow navigation still moves selection and focus. Button accessibility and keyboard activation remain native.

Focused tab buttons also publish the existing control-focus value used by the window's Space shortcut. The before Preview confirmed that Space incorrectly toggled playback while a tab had focus. The exemption lets Space activate the focused button and leaves transport Space available outside controls.

## Reasoning

Selection and focus represent different states. Separating pointer focus dismissal from the Button action avoids clearing focus during keyboard activation. No application-wide event monitor, custom focus outline, or focus suppression is needed. Apple's [simultaneous gesture API](https://developer.apple.com/documentation/swiftui/view/simultaneousgesture(_:including:)) lets this pointer behavior run alongside the existing Button interaction.

## Technical debt

None.

## Validation

- Before screenshot: `/tmp/gday-tab-focus-evidence/before.png`, synthetic Preview from `/private/tmp/gday-mute-validation`.
- `make format-macos` and `make lint-macos` passed.
- Isolated `make build-macos-preview` passed, including the production release build, bundle validation, and signing (71 seconds). Build log: `/tmp/gday-tab-focus-build-final.log`. macOS 26.6.2. Existing Command Line Tools linker warnings about missing `Developer/Library/Frameworks` and `Developer/usr/lib` remain; no deprecation warnings occurred. These are toolchain search-path warnings, not introduced by the focus change; validate with a complete Xcode installation when available.
- Direct checks passed: pointer selection shows no focus border; Tab navigation shows focus; Space activates Notes while preserving focus and leaving playback paused; Right Arrow selects and focuses Data Privacy. Return preserves native focus and does not activate this borderless button. Accessible button labels and selected traits remain present.
- A physical pointer click from keyboard-focused Data Privacy to Summary cleared keyboard focus. Accessibility activation through the automation tool's element action retained focus, as intended for assistive activation. After captures, the UI tool returned `cgWindowNotFound`; further same-tab repetition, reverse traversal, outside-control playback Space, dark appearance, and smaller-window checks were not completed. No global keyboard behavior or layout is changed.
- After screenshots: `/tmp/gday-tab-focus-evidence/after-pointer-light.png`, `after-keyboard-space.png`, and `after-keyboard-arrow.png`. The `after-pointer-clears-keyboard.png` capture records accessibility activation, not a physical pointer click; it correctly retains the ring.
- The first working-tree snapshot failed to compile an unrelated, concurrently edited voice-library call. Final validation uses committed `bc12b24` plus this task's tab change in `/private/tmp/gday-tab-focus-validation`; it does not incorporate or repair those in-progress edits.
- Screenshot binaries stay outside Git. This task changes no saved meeting data.
