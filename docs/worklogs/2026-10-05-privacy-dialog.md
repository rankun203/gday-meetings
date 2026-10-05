---
title: Meeting Data Privacy dialog
date: 2026-10-05
status: complete
scope: swift-app
---

## Problem

Data Privacy occupied a meeting content tab. The requested location is the meeting's More menu, opening a dialog.

## Design evidence

Inspected the supplied screenshot and captured the existing menu and Data Privacy tab in synthetic Preview before editing. The menu contains transcription, export, and archive actions; privacy history has a title, file-reveal action, explanatory text, and expandable event groups. Move the privacy action into its own menu section before export. Preserve the existing history view in a 680-by-520-point native sheet with a trailing Done button and Escape dismissal. Keep Transcript, Notes, and Summary as the three content tabs; preserve the selected tab and playback when opening and closing privacy history.

## Implemented solution

Removed the Data Privacy segment and enum case. Meeting Actions now presents the existing history view in a sheet. Updated the shared UI guide and native toolbar layout test for the three remaining tabs.

## Reasoning

Reusing the existing privacy view preserves its event grouping, transfer receipts, and file-reveal behavior. Sheet state belongs to the selected meeting's action menu and does not change content-tab selection. No duplicate privacy implementation or navigation compatibility bridge is needed because tab state is window-local.

## Technical debt

None introduced. The existing history reader polls file metadata and reads changed history off the main actor. The separate responsiveness audit assesses remaining synchronous work.

## Validation

All 25 initial targeted tests passed serially in 0.442 seconds. The integrated 74-test run also passed, including native toolbar selection/layout, retained workspace state, and data-event history. Formatting, lint, and whitespace checks pass. The integrated release built in 154.45 seconds without warnings and passed platform/signature validation.

Rebuilt Preview `40e64af-responsiveness-ui` on macOS 26.6.2 shows only Transcript, Notes, and Summary. Data Privacy appears in the More menu before Export. Inspected the 680-by-520-point sheet in Light and Dark appearance: title, reveal control, expandable groups, scrolling content, and Done remain readable. Expanded a summary receipt. Escape and Done both return to the previously selected Summary tab with the player still paused at the same position. Captures are in the computer-use session and contain synthetic data only. No Finder action or real transfer was started. System appearance, empty history, and VoiceOver speech were not separately exercised.
