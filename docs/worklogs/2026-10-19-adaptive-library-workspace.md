---
title: Preserve the preferred native library layout
date: 2026-10-19
status: implemented
scope: macos-library-layout
---

# Problem

The user prefers the Claude candidate's native meetings-list sizing: the list can be wider with the sidebar closed and narrower with it open, leaving more space for the transcript.

User-adjusted listing widths also need to survive page changes and app launches, with separate choices for the expanded and collapsed sidebar. The user requested this across listing pages and approved adding a draggable divider to Tasks.

# Implemented solution

Integrated the user-tested candidate's two source changes. `LibraryView` bounds the navigation workspace within its share of the vertical stack above the persistent transport. `GdayMeetingsApp` applies the window minimum directly to the root content. Existing native split columns, width preferences, sidebar identity, and divider behavior are retained.

`ListWidthPersistence` saves visible list widths in preferences for Meetings, People, Tags, and Tasks, separately for each sidebar state. Voice Library has its own standalone preference. A marker in each native split restores the preference once when its page or sidebar context changes. It accounts for native safe-area insets and applies native divider constraints. Tasks now has a native draggable divider, with its existing 340-point width as the initial preference.

# Reasoning

The supplied screenshots established the layout under investigation. The user tested the signed Claude candidate against the main library and selected its list-width behavior. Integration preserves that tested implementation with an intent-focused comment. The earlier Astra custom divider remains isolated in its comparison worktree.

The chevron and animation defect is state-dependent and remains unresolved. The user subsequently observed smooth behavior in the installed app and both full-app candidates. This layout preference establishes the scope of this change; it provides limited evidence about the intermittent defect.

Only AppKit notifications identified as user divider drags update preferences. Window resizing and programmatic restoration retain the saved choice. The supported [split-view resize notification](https://developer.apple.com/documentation/appkit/nssplitview/didresizesubviewsnotification) supplies the drag flag and divider index on the minimum supported macOS version. Restoration occurs once through native layout; animation timing remains part of user validation.

# Technical debt

The quantified [layout debt register](../macos-layout-technical-debt.md) tracks three open SDK-migration items, including 170 lines of hierarchy/lifecycle bridge code and three explicit geometry boundaries. It records risk, retained behavior, failure signals, validation limits, and removal criteria.

Retained: the existing native sidebar action bridge discovers the split controller through the view hierarchy. Its maintenance consequence and future replacement with an equivalent supported SwiftUI action remain documented in the October 14 persistent-sidebar worklog. The nested native split and geometry boundaries remain part of the existing design and require coverage when changing window layout.

Added compatibility bridge: the preference marker locates its enclosing native split because SwiftUI's `HSplitView` exposes no divider-position binding. It uses public AppKit sizing and notification APIs, retaining native divider behavior. SwiftUI hosting-hierarchy changes may require adapting discovery. Replace this bridge when SwiftUI provides a supported divider-position binding; the offscreen native test covers the current persistence contract.

# Notes

Visual validation of the candidate layout was performed by the user. The final `make build-macos` release build passed in the isolated Claude checkout, with macOS 26 minimum and SDK 27. Scoped strict Swift formatting and diff checks passed. All five `ListWidthPersistenceTests` passed in release configuration, including the offscreen native split with nonzero safe-area insets.

The linker reported two missing Command Line Tools search directories (`Developer/usr/lib` and `Developer/Library/Frameworks`); these are local toolchain search-path warnings. The reused test cache also reported stale paths from an earlier validation checkout. A fresh build cache and complete selected Xcode toolchain are the follow-up for these environment warnings. Source deprecation warnings were absent from the release build.

Post-push macOS CI checks are pending. The production app and library remain under the user's control during integration. The user will validate the new divider interactions and saved widths, including sidebar transitions with changing safe-area insets.
