---
title: Notes header and recording control layout
date: 2026-09-29
status: complete
scope: swift-ui
---

# Notes header and recording control layout

## Problem

During recording, the Notes title and save notice occupied a separate row above the Edit/Read control. Muted source symbols had different intrinsic widths, shifting their labels. Markdown Copy Code buttons reserved an unnecessary row above code.

## Implemented solution

- Moved the recording Notes title and save notice into the workspace control row. The notice sits immediately left of Edit/Read, with the title at the leading edge.
- Gave microphone and system-audio symbols an 18-point square slot so muted and unmuted labels share a fixed origin.
- Changed shared Markdown Copy Code controls to float at the top right of each code block.
- Corrected cursor event priority: the parent Markdown text view no longer overwrites its embedded button's pointing-hand cursor. Native buttons handle cursor events directly; SwiftUI controls use native pointer styling on macOS 15 and later, with continuous hover handling on macOS 14.

## Reasoning

One header row gives more room to notes. Fixed symbol slots preserve layout across source states. Floating copy controls keep code blocks compact.

## Validation

Inspected user screenshots and captured the isolated synthetic recording Notes view before editing. All 464 tests in 89 suites passed; preview build, lint, formatting, and whitespace checks passed. Existing Command Line Tools linker search-path warnings remain; no source deprecation warnings were reported.

Final screenshots confirm one Notes header row with the notice directly left of Edit/Read, stable microphone and system-audio label origins in both mute states, working Read mode, and compact code blocks with floating Copy Code buttons. Code retains a trailing inset to avoid button overlap. No real recording was used. Synthetic recordings were stopped and saved after validation. Narrow-window and dark-appearance combinations were not repeated for these layout-only adjustments.

## Technical debt

None.

## Follow-up validation

Added a regression check that sends cursor events through the real Copy Code button and its parent in both orders, checks disabled-button behavior, and checks return to the text-selection cursor. All 467 tests in 89 suites passed, including this event-level regression.
