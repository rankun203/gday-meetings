---
title: Inactive toolbar branding
date: 2026-10-03
status: complete
scope: swift-app-ui
---

## Problem

The custom toolbar logo and title stayed bright when the window became inactive, while native toolbar icons dimmed. The same issue affected destination titles.

## Implemented solution

`LibraryView` renders the logo as a template and applies the system label color while active and disabled control text color while inactive. A toolbar-local modifier reads SwiftUI's `appearsActive` environment value. Layout, controls, and accessibility text stay unchanged.

## Reasoning

The existing Preview screenshot confirmed the brightness mismatch. The design keeps the logo and title in their current positions and changes only their semantic foreground color. Reading activation inside the toolbar follows native toolbar behavior, including main-window behavior when a settings window has focus. Apple's supported [appearsActive API](https://developer.apple.com/documentation/swiftui/environmentvalues/appearsactive) is back-deployed before macOS 15 and supports the app's macOS 14.2 minimum without deprecated APIs or custom window observers.

## Technical debt

None.

## Validation

- Captured and inspected the existing synthetic Preview before editing.
- Formatting and lint passed.
- Isolated `make build-macos` passed in 142.16 seconds, including property-list and signature validation. The validation tree used committed sources plus this change; unrelated work in the main checkout was excluded.
- Captured and inspected active and inactive light/dark Preview screenshots. The logo and title dim together with native icons and restore on activation, without movement. Evidence: `/tmp/gday-branding-{light,dark}-{active,inactive}.png`.
- Opened and closed Settings with Command-comma and Command-W. The capture tool targets the front window, so the main toolbar while Settings owns focus remains visually unverified. Minimum-version runtime, System appearance, alternate window sizes, and accessibility preference combinations were not rerun for this color-only change.
- Existing linker warnings report missing Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search paths. No API deprecation warnings appeared. These environment warnings also affect prior builds; repair the toolchain installation separately if they persist after updating.
- No new interface wording was added. Reviewed the worklog against the writing guide. The installed app and user recordings were not modified.
