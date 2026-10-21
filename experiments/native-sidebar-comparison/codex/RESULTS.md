---
title: Astra native sidebar reference results
date: 2026-10-19
status: user-validated
scope: native-sidebar-comparison
---

# Findings

The optimized build and signature checks passed. The user tested sidebar reveal and resizing during the transition and reported "Smooth throughout." This establishes a working native baseline on the user's machine, without identifying which production difference causes the defect.

The supplied screenshots were inspected before implementation. They show content retaining its previous width during sidebar reveal and then reflowing, plus a separate state with a persistent blank strip. The user reports that both previous production-layout candidates retained the defect. Those observations motivate this baseline; they do not establish its outcome or identify the responsible framework.

# References

- [Apple: NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) describes a navigation container with up to three columns, typically placed at the scene root. Column widths are preferences that the system can adjust.
- [Apple: balanced](https://developer.apple.com/documentation/swiftui/navigationsplitviewstyle/balanced) describes a style that makes space for leading columns by reducing the detail area. It specifies layout intent, not frame-by-frame animation behavior.
- [Apple: doubleColumn](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility/doublecolumn) defines the initial three-column visibility used here: content and detail visible, sidebar hidden.

# Experiment setup

`NativeSidebarApp.swift` places one three-column `NavigationSplitView` directly inside `Window`. It uses `.balanced`, an initial `.doubleColumn` preference, a 1,200-by-800-point default window, native list selection, and `SidebarCommands`. Sidebar widths are 180/200/240 points for minimum/ideal/maximum; list widths are 250/300/360 points. The detail has no explicit width constraint and contains twelve synthetic paragraphs in a scroll view.

`NativeState` is a type alias for SwiftUI's standard `State` property wrapper. It avoids a Command Line Tools macro-name conflict without changing runtime state behavior. The app has no storage integration, custom toolbar, geometry reader, nested split, custom animation, introspection, or layout forcing.

`build.sh` produces an optimized native-architecture executable with a macOS 26.0 deployment target and the current selected SDK. Its unique bundle identifier separates its preferences from the production app. All generated files are written outside the repository.

# Results

| Check | Result |
| --- | --- |
| Optimized build and linked platform | Passed: arm64, macOS 26.0 minimum, SDK 27.0 |
| Property list and signature verification | Passed: valid property list and strict ad hoc signature verification |
| Swift formatting and shell syntax | Passed |
| Sidebar reveal and resizing during transition | User reported smooth throughout |
| Sidebar toggle overflow | No issue reported in the combined test |
| Persistent blank strip or displacement | No issue reported; intermittent production failure not ruled out |
| Divider resizing and selection | Pending user validation |

The built app is `/private/tmp/gday-native-sidebar-comparison/Astra Native Sidebar.app`. Its verified bundle identifier is `com.gdaymeetings.native-sidebar-codex`. The final optimized build emitted no compiler, linker, or deprecation warnings.

Content reflow means wrapping responds to the available detail width during the reveal. Toolbar overflow means the standard sidebar toggle becomes unavailable in the visible toolbar and moves into its overflow menu. Persistent displacement means a gap or offset remains after the animation stops. These are separate observations and should be recorded independently.

The user performed visual validation; no agent launch or UI automation was used. No timing trace or frame-by-frame measurement has been collected, and synthetic text does not reproduce every sizing demand of the production app. This successful baseline narrows the next investigation to differences in the production hierarchy without proving which difference causes the defect.

# Technical debt

None. This is a standalone reference, with no production integration or compatibility behavior beyond selecting the standard SwiftUI property wrapper by type alias.
