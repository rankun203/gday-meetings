---
title: Preserve meeting list top spacing
date: 2026-09-26
status: complete
scope: swift-app-ui
---

## Problem

Adding meetings to a scrollable list moved its first row against the top edge. Scrolling upward restored the native 10-point gap. In UI Preview, creating 15 notes reproduced the issue: the scrollbar moved from zero to 0.0325733 and the first row moved upward by 10 points.

## Implemented solution

`LibraryView` reveals added meetings with `ScrollViewProxy.scrollTo` using center alignment. Native scrolling clamps a new first row to the beginning of the document, including the list's existing inset. Older imported meetings appear near the middle of the viewport.

## Reasoning

The forced top anchor aligns the row with the viewport edge, scrolling past the inset list's native spacing. Apple's [scrollTo documentation](https://developer.apple.com/documentation/swiftui/scrollviewproxy/scrollto(_:anchor:)) describes the alignment behavior. The default anchor also loses the inset when revealing an inserted row, so it was rejected after native Preview and offscreen checks. Center alignment uses native scroll limits without adding padding, compensating offsets, or an AppKit bridge. The existing zero additional content margin remains unchanged; the native list still provides its own 10-point inset.

## Validation

The original behavior was reproduced in UI Preview with an overflowing synthetic list. An offscreen SwiftUI list probe measured native clip-view origin moving from 0 to 10 points after insertion with the default anchor, and remaining at 0 with center alignment.

Passed: `LibraryScrollTests` exercises the production `LibraryView` with an overflowing library, adding meetings at the top and while browsing older rows, and preserving the scroll position during ordinary store updates. The focused run with `RecordingMeterTests` passed all nine tests. Formatting and Preview packaging passed. Packaging still reports the previously documented Command Line Tools linker search-path warnings; no source deprecation warning was introduced.

Final visible Preview checks passed: 16 new notes overflowed the list while its scrollbar remained at zero and the native 10-point inset stayed visible. Adding another note after scrolling to the bottom returned to zero with the inset intact. Selection, play/pause, and People → Meetings navigation preserved the position and spacing.

## Technical debt

None.
