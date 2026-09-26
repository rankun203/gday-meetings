---
title: Meeting title editing height
date: 2026-09-26
status: complete
scope: swift-app-ui
---

# Meeting title editing height

## Problem

The meeting detail title clipped its large text and insertion point after entering edit mode. The header used a single-line plain TextField, whose focused editor did not fit the title's font metrics. An outer minimum height did not control that editor's text layout.

## Implemented solution

`MeetingDetailView` uses SwiftUI's vertical-axis TextField for the title, with one to three visible lines. The native editor measures its line height, and longer titles wrap before scrolling. The playback button stays at the top of the title row. The header no longer gives the title an arbitrary 40-point minimum height.

## Reasoning

Use the supported native multiline editor to measure large editable text, preserving keyboard editing and accessibility. An outer frame or extra padding would not correct the single-line editor's internal metrics. Apple's [TextField axis initializer](https://developer.apple.com/documentation/swiftui/textfield/init(_:text:axis:)-7n1bm) is available from macOS 13, below this app's macOS 14.2 minimum. The current Apple documentation and SDK were checked; no deprecated API was introduced.

## Technical debt

None.

## Validation

Formatting, lint, all 217 integrated tests, and Preview packaging passed. Preview checks verified the user’s date-style title while focused and a longer two-line title with the final character selected. Text and selection were fully visible; the playback button remained aligned and the list title updated.
