---
title: Claude Native Sidebar results
date: 2026-10-19
status: pending-ui-validation
scope: experiment
---

# Claude Native Sidebar results

## Findings

There are no UI results yet. The app is a minimal SwiftUI baseline: a three-column `NavigationSplitView` is the only root view in the window. A smooth sidebar animation would suggest testing additions made by the production app. Shudder in this baseline would make the local SwiftUI or AppKit behavior a stronger suspect, without proving its cause.

Build status: optimized compilation, ad-hoc signing, and strict signature verification passed when the coordinator ran `./build.sh` outside the nested agent sandbox. The binary targets macOS 26.0 and SDK 27.0. The Swift source passes `swift-format lint --strict`, and `bash -n build.sh` passes. The build log contains no warnings. Earlier sandboxed attempts could not run the SwiftUI macro plugin.

## References

- [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview): the three-column initializer `init(columnVisibility:sidebar:content:detail:)` binds visibility to a `NavigationSplitViewVisibility` value.
- [NavigationSplitViewVisibility.doubleColumn](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility/doublecolumn): in a three-column split view, this value hides the sidebar and shows the content and detail columns.
- [SidebarCommands](https://developer.apple.com/documentation/swiftui/sidebarcommands): adds the standard sidebar commands, including **Show Sidebar** / **Hide Sidebar**, to the View menu.
- [navigationSplitViewColumnWidth(min:ideal:max:)](https://developer.apple.com/documentation/swiftui/view/navigationsplitviewcolumnwidth(min:ideal:max:)): sets the width range of a column.
- [defaultSize(width:height:)](https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:)): sets a window's initial size.

## Experiment Setup

**Baseline app.** `Sources/NativeSidebarApp.swift` defines a `WindowGroup` titled "Claude Native Sidebar" with a default size of 1200 × 800 points and `SidebarCommands`. The window content is a view whose `body` is only `NavigationSplitView(columnVisibility:)`. Nothing wraps it: no `GeometryReader`, nested split view, root stack, footer, search field, custom toolbar, view introspection, forced layout, custom animation, or timer.

| Column | Content | Width (min / ideal / max) |
| --- | --- | --- |
| Sidebar | `List` of 5 synthetic categories with SF Symbols | 180 / 200 / 240 |
| Content | `List` of 8 synthetic entries for the selected category, each with a one-line preview | 250 / 300 / 360 |
| Detail | `ScrollView` containing a `VStack` with the entry title and 14 long wrapping paragraphs; `navigationTitle` set to the entry title | Fills the remaining width |

**State.** Column visibility is a `@State` value that starts as `.doubleColumn`, so the sidebar starts hidden. At launch, the first category and its first entry are selected. Choosing a different category selects its first entry. All content is built once from a fixed sentence pool, so every launch shows the same text.

**Bundle.** Identifier `com.gdaymeetings.native-sidebar-claude`, display name "Claude Native Sidebar", minimum macOS 26.0. `build.sh` compiles with `swiftc -O -parse-as-library -target arm64-apple-macosx26.0` against the current macOS SDK, then ad-hoc signs and verifies the bundle.

**Shudder.** In this report, *shudder* means visible back-and-forth jitter, flicker, or repeated relayout of any column while the sidebar animates in or out, as opposed to a single smooth slide.

## Results

| Check | Method | Result |
| --- | --- | --- |
| Swift lint | `swift-format lint --strict` with the macOS app configuration | Passed |
| Build script syntax | `bash -n build.sh` | Passed |
| Compile, sign, and verify | `./build.sh` outside the agent sandbox | Passed; macOS 26.0 minimum, SDK 27.0 |
| Sidebar hidden at launch | Open the app; content and detail columns should be visible | UI pending |
| Toolbar sidebar button | Click it repeatedly to show and hide the sidebar | UI pending |
| View menu command | **View > Show Sidebar** / **Hide Sidebar** and Control-Command-S | UI pending |
| Shudder during sidebar animation | Watch every column while showing and hiding the sidebar | UI pending |
| Text wrapping | Resize the window and toggle the sidebar; detail text should rewrap at the column edge | UI pending |
| Column width limits | Drag the dividers; widths should stay within the limits in Experiment Setup | UI pending |
| Category selection | Choose a different category; its first entry should appear in the detail column | UI pending |

## Limitations

- The checks are visual and manual. No frame timing or animation trace is recorded.
- The app targets Apple silicon and macOS 26 or later only.
- The baseline isolates the split view. A smooth result here doesn't show which production addition causes the shudder. Finding that needs more ablations.
