---
title: Restore a window when the app becomes active
date: 2026-10-01
status: validated
scope: swift-app
---

# Window activation

## Problem

The pending Dock handler restored the Meetings window only for reopen events. Switching to the app with Command-Tab after closing its windows could leave it without a usable window.

## Implemented solution

`MeetingsAppDelegate` sends app activation and Dock reopen events through `MainWindowLifecycle`. Visible Settings, document windows, and dialogs leave Dock ordering to AppKit. Otherwise, a deferred check restores a minimized window or opens the existing SwiftUI `main` scene. Status and menu windows do not count as usable application windows. The opener remains registered after the main view closes.

Requests are coalesced, reentrant restoration is suppressed, and the check is cancelled if the app becomes inactive or starts quitting. A failed quit restores normal activation handling. Closing a window alone does not trigger restoration. The three activation calls in the app entry point now use the supported `NSApplication.activate()` API, available within the macOS 14.2 minimum.

## Reasoning

Use the application delegate lifecycle because a closed SwiftUI view cannot reliably observe later activation. Keep the Dock callback because clicking an already-active app need not produce another activation event. Deferring the check lets native activation and existing SwiftUI presentation requests settle before deciding whether a new presentation is needed. The SwiftUI singleton remains the final protection against duplicate main windows.

Apple references: [activation callback](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdidbecomeactive(_:)), [reopen callback](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)), and [activation API](https://developer.apple.com/documentation/appkit/nsapplication/activate()).

## Validation

Inspected the isolated preview baseline at `/private/tmp/gday-activation-before.png`: normal synthetic Meetings content, paused playback, and no modal. The intended result is the same singleton scene, with no layout changes. Tests exercise native window classification, minimized reuse, closed versus visible windows, deferred startup presentation, coalescing, reentrancy, lost activation, and quit cancellation. Presentation methods are intercepted in tests to avoid controlling other application windows.

The main agent reproduced the failure in a fresh isolated validation bundle: closing the main window through Accessibility succeeded; subsequent native activation returned success, but the active app still exposed zero Accessibility windows. No real recording was controlled.

All 524 tests in 97 suites passed in 63.56 seconds, including seven new lifecycle tests. Repository Swift formatting, lint, and diff whitespace checks passed. The isolated signed release build passed in 55.08 seconds. Initial validation found actor-isolation warnings in default callback arguments and a test-only stored-property collision with AppKit; explicit main-actor callback types and distinct fixture names resolved them. The final build retains only the known Command Line Tools linker search-path warnings; no new deprecation warning remains.

Post-change checks used one-shot native Accessibility and keyboard tools, with no Computer Use helper or screen stream. Closing the synthetic main window left it closed. Command-Tab away and back restored exactly one Meetings window. Launch Services reopen events restored the window while already active, and repeated reopen requests kept one window. A minimized window was reused on native activation. A visible Settings window remained the only window on Command-Tab. Follow Logs accepted its menu action and Console was running afterward. The installed real app and recording were not modified or restarted.

Captured and inspected `/private/tmp/gday-activation-after.png`. The recreated scene retains the library/sidebar and shared paused playback; its view-local meeting selection is empty after recreation. No layout or controls changed. Multi-Space/full-screen behavior, alternate appearances, manual Dock clicking, and a real recording during these lifecycle transitions were not exercised. Early multi-process keyboard checks sometimes switched to the test host rather than the target app; a bounded single-process check confirmed the actual Command-Tab path. CI release results are recorded after pushing.

The pushed implementation passed the [macOS release CI matrix](https://github.com/rankun203/meeting-notes/actions/runs/36823851899) on macOS 15, 26, and 27 (runner preview). All runners were available and all three builds succeeded.

## Technical debt

No new application debt. Window classification uses public AppKit properties; no private class names or polling are introduced. The existing Command Line Tools installation references missing `Developer/usr/lib` and `Developer/Library/Frameworks` search directories. Builds succeed without suppressing the warnings; repair or update that installation and rerun the release build to remove them.
