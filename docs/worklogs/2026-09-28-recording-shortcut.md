---
title: New Recording keyboard shortcut
date: 2026-09-28
status: complete
scope: swift-app-ui
---

# New Recording keyboard shortcut

## Problem

Command-N created an empty meeting immediately, unlike the New Recording toolbar button. Preview’s File menu confirmed the separate New Meeting command.

## Implemented solution

The File menu now exposes New Recording… with Command-N and opens the existing recording setup sheet. It creates no meeting until recording starts. The command is disabled while recording starts, runs, or finishes, and when the library cannot be written. The explicit New Meeting Notes toolbar-menu action remains available.

## Reasoning

The shortcut should open the same setup workflow as the visible New Recording control. Reusing the existing sheet preserves source selection, language, and Cancel behavior.

## Technical debt

None.

## Validation

The consolidated 392-test suite and release Preview build passed. In isolated Preview, Command-N opened the New Recording setup sheet. Cancel returned to the same meeting list without creating an empty meeting. No recording was started.
