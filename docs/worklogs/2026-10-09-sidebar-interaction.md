---
title: Sidebar hover and selection response
date: 2026-10-09
status: partially-superseded
scope: swift-app-ui
---

## Problem

The library sidebar did not show hover feedback. Navigation listened only to AppKit's final table-selection notification, so it did not publish the selection during mouse tracking. The reported delay was about 200 ms; that duration has not been independently measured.

## Implemented solution

The original change published selection from both the changing and final selection notifications. Real-click validation on October 13 reproduced a navigation reversal during split replacement. The [selection correction](2026-10-13-sidebar-selection.md) removes intermediate publication and retains the equality check. Navigation now uses the completed notification for mouse and keyboard selection.

A native `NSTableRowView` subclass adds an unselected hover background with `quaternaryLabelColor`. Tracking follows the visible row in the key window. Exit and window removal clear hover. Row size, labels, symbols, native selection drawing, keyboard handling, and accessibility remain under AppKit's control.

## Reasoning

The supplied screenshot and a synthetic capture showed the existing five-row sidebar. The design keeps those rows in place and adds a quiet rounded background under the hovered row. Selected rows retain their native highlight. Hover does not select or move a row.

The original assumption was that publishing during mouse tracking would improve perceived response. No end-to-end timing established that benefit. The control was replaced during its own tracking interval, allowing a stale selection to overwrite navigation. The completed notification avoids that reproduced failure.

References: Apple's [table-selection notifications](https://developer.apple.com/documentation/appkit/nstableview) and [native row drawing](https://developer.apple.com/documentation/appkit/nstablerowview), reviewed October 9, 2026. These APIs are available below the app's macOS 26 minimum.

## Technical debt

Retained: original click latency and real pointer-only hover delivery were not validated. The synthetic tests and captures below establish component behavior only. Complete full-window interaction measurements before claiming those original issues are resolved.

## Validation

- Five tests passed in an isolated package containing the production sidebar and its focus and interaction tests. New coverage checks navigation before the final selection notification, duplicate notification handling, focus request consumption, keyboard notification handling, hover exit, stable geometry, and tracking-area replacement.
- Captured the production component before editing and after editing. Inspected final light and dark captures with synthetic selection and hover. Row geometry and labels remain stable, with hover separate from selection. Captures and the temporary harness are ignored under `tmp/sidebar-interaction/`.
- Capture provenance: source revision `d253398` plus this working change; command-line probe built from the production source; Darwin 25.6.0; Apple Swift 6.4; capture date October 9, 2026. The harness uses an offscreen window that models key-window state, with no library, Keychain, capture, playback, or provider access.
- Limits: offscreen capture does not reproduce the native window compositor's selection material. The delegate test establishes when the binding is written, not end-to-end click latency or displayed-frame timing. Full-window pointer, VoiceOver, Increase Contrast, inactive-window, and Reduce Motion checks remain unverified. Combined release validation is recorded in the sidebar-sizing worklog.
- The standalone Command Line Tools test runner initially omitted its Testing macro plugin. Loading its installed plugin explicitly, as the repository's test script does, allowed the tests to pass. No deprecation warnings were emitted by the successful focused build.
