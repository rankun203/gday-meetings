---
title: Notes mode control
date: 2026-09-27
status: implemented
scope: swift-app-notes-ui
---

## Problem

The Edit/Read segmented control sits outside the notes panel and uses space above its content. The user requested a compact icon control inside the upper-right corner.

## Design before implementation

Inspected the supplied September 27 11:40 screenshot before editing. Use one native bordered button in a fixed panel header: a book switches to Read, and a pencil switches to Edit. Give it a 28-point target, next-action tooltip and accessibility label, and a current-mode accessibility value. Reserve header space so text and images never sit underneath it. Keep the editor mounted while reading to retain selection and undo history, and retain the workspace's existing watcher lifetime and save-before-switch guard.

## Implemented solution

Replaced the segmented picker with a book/pencil button in a fixed header inside the shared notes panel. The editor remains mounted beneath Read mode to retain selection and undo history; while hidden it is noneditable, inaccessible, and unable to receive pointer input. Disabling its native text view resigns that view if it was first responder. The workspace still owns the directory watcher and flushes pending notes before changing modes. Empty-state wording now names Edit Notes.

Formatting, lint, and all 313 tests across 65 suites passed (8.405 seconds). The native mode-switch regression passed: disabling editing resigns keyboard focus, retains the selection, and preserves undo after editing resumes. The signed production build passed (38.04 seconds), with existing Command Line Tools linker search-path warnings. Native visual checks have not run because the current app contains an active user fixture.

## Technical debt

Native visual checks remain pending; the active user fixture will not be replaced or closed for this change.
