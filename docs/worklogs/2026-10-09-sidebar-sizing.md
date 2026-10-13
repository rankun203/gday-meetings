---
title: Sidebar transition sizing investigation
date: 2026-10-09
status: blocked
scope: swift-app-ui
---

## Problem

Opening or closing the library sidebar temporarily moves content beyond the window before it returns to its final position. The supplied transition screenshot also shows the native toolbar overflow control appearing temporarily. An installed-app screenshot confirmed the existing toolbar and centered no-selection appearance before investigation.

## Design

Preserve native split navigation, its toolbar and animation, existing column widths, page layouts, and empty-state content. Keep the player and task status below the workspace with their existing height allocation. A fix must eliminate conflicting sizes during the transition without clipping content or postponing updates.

## Implemented solution

Added a synthetic AppKit containment test in `LibrarySidebarTests.swift`. It invokes the native `NSSplitViewController` action in both directions at 900- and 1200-point window widths and samples the split, columns, detail descendants, and available presentation layers. The fixture has one unselected meeting and a failed preview task to display the task status bar.

No production sizing change is retained. A proposed `GeometryReader` boundary was removed because the original layout passed the containment checks; those results did not establish that this boundary would fix the reported defect or preserve the full native toolbar. The separate [sidebar interaction change](2026-10-09-sidebar-interaction.md) adds hover feedback; its earlier selection publication was removed by the [October 13 correction](2026-10-13-sidebar-selection.md).

## Reasoning

The production toggle comes from `NavigationSplitView`. `LibrarySidebarControl` invokes a separate diagnostic action, so changing that helper's animation curve would not fix the toolbar action. The new test exercises the native controller directly.

The test observed intermediate detail widths in both directions, but no overflow beyond the one-point boundary tolerance. Separate diagnostic runs with a SwiftUI detail-background marker also passed. These measurements do not reproduce the supplied screenshot. An AppKit-hosted test is not equivalent to the production SwiftUI window scene and its toolbar/compositor integration.

Apple's [layout documentation](https://developer.apple.com/documentation/swiftui/laying-out-a-simple-view) describes parent size proposals and child responses. [GeometryReader](https://developer.apple.com/documentation/swiftui/geometryreader) exposes container dimensions and reports a flexible preferred size. Neither contract establishes the cause of this particular transition defect.

## Technical debt

Retained: the reported resize defect remains unresolved. No speculative sizing wrapper, animation suppression, clipping, delayed update, or toolbar replacement was added. Follow-up: reproduce the full window transition, measure the detail content and toolbar in that scene, then compare a targeted fix at intermediate frames and settled layouts.

## Validation

- Synthetic test runs covered an empty library, an unselected meeting, and an unselected meeting with a task status bar. Original production sizing passed all those containment checks. This is a coverage addition, not evidence that the reported defect is fixed.
- Evidence and isolated source/build files are under ignored `tmp/sidebar-sizing-20261009/`; diagnostic logs are `/tmp/sidebar-baseline*.log`. Baseline revision was `d253398`, with pre-existing transcript scrollbar work copied into the isolated build. Those transcript changes belong to another task. macOS 26.6.2, Command Line Tools Swift 6.4, SDK 27.0.
- The Computer Use tool repeatedly rejected the isolated Preview with “Computer Use was not approved to use Gday Meetings,” including after the user explicitly authorized access and the tool session was reset. That blocked the original full-window sizing validation. October 13 Preview access succeeded for navigation checks, but the sizing defect remains unreproduced. The installed app and its active work were not rebuilt, replaced, or closed.
- October 13 combined release build passed; 20 tests in six suites passed, including the containment test. These checks do not establish a fix for the reported sizing defect.
