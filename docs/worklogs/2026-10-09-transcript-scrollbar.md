---
title: Preserve native transcript scrollbar drawing
date: 2026-10-09
status: pending-visual-validation
scope: macos-transcript-ui
---

## Problem

The transcript's overlay scrollbar had a flat, clipped right edge. A capture of the running screen and an isolated AppKit comparison reproduced the defect in the custom `NSScroller` subclass; the standard scroller retained its rounded thumb. Both controls reported the same frame and knob geometry. Disabling view clipping did not correct the custom scroller's drawing.

## Design

Use the standard AppKit scrollbar at the existing transcript edge. Preserve the text width, system scrollbar style, thumb drag behavior, and suspension of automatic following during user scrolling. Do not add padding or custom thumb drawing to compensate for the defect.

## Implemented solution

Removed `TranscriptNativeScroller`. `TranscriptNativeScrollView` observes its own live-scroll start, change, and end notifications to pause following and bracket tracking. The existing wheel handler remains for wheel input. Notifications from other scroll views and programmatic transcript movement do not pause following.

## Reasoning

AppKit owns scrollbar drawing and sizing. Its [live-scroll notifications](https://developer.apple.com/documentation/appkit/nsscrollview/willstartlivescrollnotification) cover gestures and thumb tracking, so the application can preserve its interaction behavior without subclassing the scrollbar.

## Technical debt

None.

## Validation

- 39 tests passed across four transcript suites, including overlay and legacy styles, tracking notification order, unrelated-scroll isolation, programmatic scrolling, and transcript geometry.
- Changed Swift files pass strict formatting; `git diff --check` passes.
- `make build-macos` passed in the isolated checkout at `/tmp/gday-reconcile-release`, with macOS 26 minimum, SDK 27, and successful bundle and signature checks. The validated source matches the workspace, and the binary contains the new scroll-notification handlers. The active recording has not been interrupted or replaced.
- The build retains existing Command Line Tools linker warnings for missing developer library search paths. No deprecation warnings were reported.
- The before-change comparison was inspected through Computer Use. Access to the isolated diagnostic app was subsequently denied with “not approved to use Scroll Check”; approval was requested for the after-change interaction and visual check. Offscreen AppKit rendering does not reliably show the standard overlay thumb and is not a substitute for that check.
