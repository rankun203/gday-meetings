---
title: macOS library layout technical debt
date: 2026-10-19
status: active
scope: macos-library-layout-sdk-migration
baseline: c516d7e
---

# Scope and measurement

This audit covers the library sidebar, list-width persistence, workspace geometry, and adjacent search/sidebar controls at `c516d7e`. The broader transcript renderer, audio stack, and other application bridges require separate audits.

Counts are physical source lines, including comments and blank lines. They measure review surface, rather than defect probability or engineering effort. Risk ratings describe reliance on framework implementation details: **high** means generated hierarchy or lifecycle assumptions; **medium** means layout composition sensitive to platform behavior; **low** means app-owned views using public APIs.

| Area | Measured surface | SDK migration assessment |
| --- | --- | --- |
| Sidebar controller discovery and action bridge | `LibrarySidebarControl.swift` lines 28–94: 67 lines | High; depends on the generated split controller and delegate arrangement. |
| List-width native marker | `ListWidthPersistence.swift` lines 61–163: 103 lines | High; depends on enclosing split identity, pane order, safe-area values, and layout timing. |
| Explicit geometry boundaries | Three `GeometryReader` plus matching explicit-size frames: library list/detail, library workspace above transport, Tasks list/detail | Medium; their composition determines intermediate sizes during native sidebar animation. |
| App-owned search field and sidebar table | `LibrarySearchField.swift`: 204 lines; `NativeLibrarySidebar.swift`: 154 lines | Low structural risk; custom appearance and focus/selection synchronization need upgrade review. These are whole-file counts, including ordinary product behavior. |

The two hierarchy/lifecycle bridges total **170 lines**. Of these, **103 lines were added in the latest width-persistence change**; the complete new helper is 163 lines, including preference keys, storage, validation, and width arithmetic. Its focused test file contains 129 lines and five tests. The 25-line diagnostic sidebar accessor preceding the existing action bridge is outside the 170-line total.

Source directory: [`apps/client-macos-swift/Sources/GdayMeetings/UI`](../apps/client-macos-swift/Sources/GdayMeetings/UI).

# Open debt

## LAYOUT-01 — Discovering SwiftUI's sidebar controller

**Priority: high at each SDK upgrade.** `LibrarySidebarActionTarget.TargetView.connect()` searches the window content tree and chooses the first `NSSplitView` whose delegate is an `NSSplitViewController` containing a sidebar item. It runs during mounting, updates, and layout. A pending reveal is dispatched to the next main-queue turn.

**Reason retained:** routes the existing sidebar actions through the native controller that owns animation, while retaining the current SwiftUI navigation shell.

**Maintenance consequence:** SwiftUI can change its hosting hierarchy, delegate arrangement, or split ordering. Discovery could select a different split or leave the action disconnected. The main-queue reveal also assumes mounting has progressed by its next turn.

**Failure signals:** an inert toggle, an unexpected pane toggling, repeated reveal requests, or a sidebar that opens only after another layout event. Evidence for this dependency is direct source inspection; its contribution to the intermittent chevron defect remains unconfirmed.

**Remediation and closure:** evaluate a supported SwiftUI sidebar action with the same reveal behavior, or an explicitly owned native split controller. Remove tree discovery and deferred reveal once the replacement passes user checks for toggle, programmatic reveal, Reduce Motion, and page changes on supported macOS versions. Prefer a small native reference reproduction before changing the production shell.

## LAYOUT-02 — Restoring widths through a generated native split

**Priority: high at each SDK upgrade.** `ListWidthPersistence.PersistenceView` walks upward to the nearest `NSSplitView`, assumes a vertical two-pane split with the list first, and restores divider zero once from its marker's `layout()`. It converts visible width using the pane's current safe-area insets.

**Reason retained:** provides separate persistent widths per page and sidebar state while preserving native divider dragging and sizing constraints.

**Maintenance consequence:** a new wrapper split, changed pane order, or different layout ordering could direct restoration incorrectly or apply it before final safe-area values arrive. Restoring the divider from a child layout callback also couples two layout lifecycles. The pending/restoring guards bound reentry, while transition timing remains a manual-validation requirement.

**Failure signals:** widths restore only on a second visit, expanded/collapsed preferences appear exchanged, widths differ after relaunch, or content jumps when restoring. The stored preferences survive automatic resizing; restore timing still needs confirmation in the production SwiftUI hierarchy.

**Remediation and closure:** replace the marker with a supported divider-position binding if one becomes available and covers this behavior. If lifecycle failures recur, evaluate an app-owned split with explicit identity, sizing, and restoration rather than adding timed retries. Preserve existing preference keys and native interaction behavior during migration.

**Stable API boundary:** AppKit documents the user-drag flag and divider index in its [resize notification](https://developer.apple.com/documentation/appkit/nssplitview/didresizesubviewsnotification). The literal dictionary keys follow that public contract. The upgrade-sensitive part is discovering and manipulating a split created by SwiftUI.

**Coverage:** five release tests cover key isolation, resize filtering, invalid values, constraint arithmetic, and an offscreen native split with safe-area insets. The fixture owns its split; production SwiftUI hosting and animated inset changes require user checks.

## LAYOUT-03 — Nested split and geometry sizing

**Priority: medium at each SDK upgrade.** The main navigation split contains native list/detail splits. Explicit geometry sizes bound both the workspace above transport and its list/detail content; Tasks now follows the same composition. Minimum and ideal widths are distributed across these containers.

**Reason retained:** preserves the user-selected Claude layout and allocates space for persistent playback/recording controls. The user preferred its flexible list sizing.

**Maintenance consequence:** changes to SwiftUI size proposals or AppKit safe-area animation can affect intermediate frames even when both settled endpoints fit. The earlier intermittent clipping, overflow chevron, and stuck resizing recovered across unchanged app builds; the underlying runtime state is still unknown.

**Failure signals:** content translates at its old width during reveal, the toolbar loses its toggle to overflow, the final frame snaps, or live resizing stops updating. This is a risk hypothesis supported by the observed symptoms, rather than an isolated cause.

**Remediation and closure:** compare the three sizing boundaries individually against the smooth native reference, using synthetic content and identical window conditions. Simplify a boundary only after user validation confirms preserved transport space, responsive detail width, and saved widths. Reassess a native three-column composition if those comparisons locate a structural issue. Record SDK, runtime OS, launch state, and window state for each reproduction.

# Customization watchlist

The search field owns its `NSSearchField` and loading layer. The sidebar owns its table, cells, selection synchronization, and hover drawing. Both use public AppKit APIs with explicit view ownership. Keep them as normal customization maintenance: review focus, keyboard navigation, accessibility, contrast, and appearance after SDK upgrades. Their full source size alone provides insufficient grounds for a layout rewrite.

# Upgrade acceptance and current limits

For each new SDK, compile with the supported deployment target and review deprecations. Ask the user to check sidebar reveal/hide, rapid reversal, resizing during motion, transport visible/hidden, page changes, and relaunch. Set distinct widths for Meetings, People, Tags, and Tasks in both sidebar states; also check Voice Library's sheet width. Use synthetic data for fixtures and preserve the active production session.

At the audit baseline, the local release build and five persistence tests passed. The user previously validated the candidate layout; visual validation of the added persistence remains pending. Automated forced-layout sampling provides limited evidence about perceived transition smoothness. Treat LAYOUT-01 through LAYOUT-03 as open until their stated closure criteria are met.
