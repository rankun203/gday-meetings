---
title: Preserve window width when revealing the sidebar
date: 2026-10-13
status: validating
scope: macos-library-navigation
---

## Problem

Opening a meeting tag with the sidebar hidden could widen the entire window. The earlier containment test checked content against the current window bounds, so window growth could pass unnoticed.

## Implemented solution

Automatic reveal invokes the library split controller's native `toggleSidebar` action when its sidebar is collapsed, matching the toolbar expand button. An always-visible detail bridge tracks that window's controller across split replacements. A pending request waits for the destination's two- or three-column controller before invoking the action. No global responder-chain action targets other windows. Regression tests measure window width in addition to content containment.

## Reasoning

Captured the unmodified full Preview at approximately 902 points wide. The native sidebar toggle preserved that width. Opening a tag through Meeting Details with the sidebar hidden expanded it to approximately 1110 points, adding the 208-point sidebar width. The intended layout retains the native sidebar and list/detail columns, reallocating available width before increasing the window. No window-frame restoration, clipping, delayed correction, or animation suppression is added.

The native action owns the expansion layout and animation. Attempts to set `NSSplitViewItem.collapseBehavior` from the sidebar or a detail background did not reach the split controller: a test observed the default policy after layout. Those attempts were removed. The final bridge locates the sidebar split within its own window and invokes the same action as the toolbar.

## Technical debt

The native action bridge finds the containing public AppKit split controller because SwiftUI's visibility binding did not match the toolbar action's layout. It depends on SwiftUI retaining a native sidebar split in the window; regression coverage checks navigation across both split shapes. Replace this bridge if SwiftUI exposes an equivalent per-window native reveal action.

## Validation

- Baseline native-toggle containment and width checks passed in three library sidebar tests. That baseline does not cover the reproduced programmatic tag route.
- Neither collapse-policy trial reached the native split. The policy assertion failed; both trials were removed.
- Corrected isolated release build passed. In full synthetic Preview at 902 points wide, Review Tasks and a meeting's Open Tag action both revealed the sidebar without changing window width. Returning from Tasks to Meetings kept the sidebar and width. Screenshots were captured and inspected through CUA with the `bac0a13-mounted-action-working` preview marker.
- Expanded automated regression checks passed in the 110-test combined run, including both initially visible and collapsed navigation. Combined production builds passed. Synthetic fixtures only; no real library was changed.
