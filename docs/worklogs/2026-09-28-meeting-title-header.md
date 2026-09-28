---
title: Compact meeting title and deliberate editing
date: 2026-09-28
status: validated
scope: swift-meeting-header
---

# Compact meeting title and deliberate editing

## Problem

The supplied screenshot shows play/pause at the opposite edge from the title. The title is always an editable multiline field, so long titles can increase the header height during ordinary reading.

## Implemented solution

Move the existing compact play/pause control immediately before the title in one vertically centered row. Display the title as one line of plain semibold text with tail truncation. A stored multiline title displays its first line followed by an ellipsis; the original value stays intact and remains available through accessibility and help.

Double-click enters a native single-line editor. A local draft commits on Enter, focus loss, or leaving the view; Escape cancels. Completing the edit ends its session before changing focus to prevent duplicate commits. The context menu and accessibility action offer **Edit Title**. Read-only libraries cannot begin editing.

## Reasoning

The title becomes a reading element until explicitly edited. This keeps header geometry stable, puts related title and playback controls together, and avoids saving every keystroke. Stored multiline data is not silently rewritten merely to display a compact header.

## Validation

Reviewed the supplied current-header screenshot and existing header implementation before editing. Parent agent owns Preview and will verify the changed layout, double-click, Enter, Escape, blur, and long-title truncation in the consolidated build. No mirrored unit test added for the layout-only transformation; interactive commit/cancel behavior requires visual validation.

Preview exposed a focus failure: double-click inserted the SwiftUI field but left Play as the first responder, so Return activated playback. The transient editor now uses an AppKit field that requests focus after window attachment and selects the entire title once. Native delegate commands commit or cancel once, including when a subsequent blur arrives. Added a window-attachment focus/selection regression and Return/Escape delegate regression. Parent agent will repeat visual editing checks after rebuilding.

Final release Preview validation passed: double-click followed immediately by typing replaced the title, Return saved it without starting playback, Escape discarded the draft, and switching to Summary committed on focus loss. A long title remained one line with a trailing ellipsis and unchanged header height. The normal title is plain text in the accessibility tree. All 420 tests in 84 suites passed, including the two native editor regressions.

## Playback hover refinement

The user's header screenshot and captured Preview baseline show a white circular playback button with barely visible hover feedback. Place an accent tint and outline above the glass material, strengthen the pressed state, and use a pointing-hand cursor. Keep the 28-point circle fixed in place. Disabled controls receive no interaction tint. Release Preview retained the compact layout and clicking toggled playback correctly. Pointer-only hover appearance remains unverified because the automation interface exposes clicks and drags but no pointer movement. This styling change adds no technical debt.

## Technical debt

None introduced. The editor uses the existing title binding and persistence path. The full stored title is preserved until a deliberate edit is committed.
