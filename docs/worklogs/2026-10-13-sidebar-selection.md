---
title: Sidebar selection during layout replacement
date: 2026-10-13
status: implemented
scope: swift-app-ui
---

## Problem

Clicking Meetings from Tasks could briefly open Meetings and return to Tasks. The October 9 working change published navigation during AppKit selection tracking, before mouse release. Its tests did not exercise a real click while SwiftUI replaced the split view. The reported original delay was not measured, and the hover captures did not establish real pointer delivery.

## Implemented solution

`NativeLibrarySidebar` commits navigation only from the completed selection notification. It retains duplicate-write protection, native selection drawing, existing focus transfer, and the separate hover implementation. The interaction regression checks that intermediate selection does not write navigation or request focus, and that the completed selection writes once.

## Reasoning

Captured the installed app before editing. The design preserves the sidebar layout and native focus appearance: selection changes once per completed action; keyboard focus remains in the replacement sidebar; hover is independent. Gray and blue selection backgrounds remain valid native inactive/unfocused and focused appearances.

A synthetic SwiftUI window using the production sidebar and the same two/three-column split replacement reproduced the failure with a real Computer Use click. The trace recorded Meetings publication, a stale Tasks update to the departing table, then Tasks publication from that same table about 106 ms after the first publication. After removing the intermediate callback, real clicks in both directions and a one-second held click remained on the chosen destination. Down Arrow after replacement selected People, confirming usable keyboard focus.

Apple documents [selectionIsChangingNotification](https://developer.apple.com/documentation/appkit/nstableview/selectionischangingnotification) as occurring while the mouse button remains down. Deferring structural navigation to the completed selection avoids replacing the control during that tracking interval. No timer, forced highlight, or mouse-event interception is added.

## Technical debt

Retained validation gap: the original perceived navigation delay and ordinary pointer-only hover delivery remain unmeasured. The correction removes the reproduced reversal; it does not establish an end-to-end latency improvement or repair an independently reproduced hover defect. Follow-up is full-window pointer/first-frame measurement and a pointer-only hover check; do not treat manual delegate calls or forced hover screenshots as substitutes.

## Validation

- Five focused sidebar interaction/focus tests passed in an isolated package using production source. The restricted test process emitted AppKit XPC connection diagnostics; no test failed.
- Synthetic probe real clicks: Tasks → Meetings → People (Down Arrow) → Tasks → Meetings (one-second hold). Each corrected transition retained its destination. Captured and inspected the corrected native sidebar appearance.
- Probe source and instrumented production copy: ignored `tmp/sidebar-regression-20261013/`. Trace: `/tmp/gday-sidebar-probe.log`. Source: `7440a8f` plus working sidebar changes; the baseline included the October 9 early-publication change. No user library, credentials, recording, or playback were accessed by the probe.
- Full production Preview real-pointer Tasks → Meetings → Tasks transitions passed, including a one-second held Tasks click. Down Arrow then selected Agents. This validates the production workspace, in addition to the reduced probe.
- `make build-macos` passed in `tmp/sidebar-sizing-20261009`, followed by a second successful release compilation during Preview packaging. The build reports the existing Command Line Tools missing `Developer/usr/lib` and `Developer/Library/Frameworks` linker search paths; no deprecation warnings were emitted. Runtime: macOS 26.6.2; toolchain: Swift 6.4, SDK 27.0; deployment minimum remains macOS 26.
- Production UI validation bundle: `tmp/sidebar-regression-20261013/Filter Validation.app`, copied from the first validated release with `GdayUIPreview` and `GdaySyntheticTasks` enabled and a separate bundle identifier. The installed app was not rebuilt or replaced.
- Full-package release tests passed: 16 tests in `LibrarySidebarTests`, `NativeLibrarySidebarFocusTests`, `NativeLibrarySidebarInteractionTests`, and `TaskQueueSessionTests`. This includes split containment, focus transfer, selection completion, and task-session state. Logs: `/tmp/gday-sidebar-fulltests.log`, `/tmp/gday-sidebar-release.log`, and `/tmp/gday-sidebar-preview.log`. Scoped Swift formatting and `git diff --check` passed. This was the pre-commit validation; subsequent release packaging and the user-authorized commit/push are covered by the [navigation worklog](2026-10-13-library-navigation.md).
