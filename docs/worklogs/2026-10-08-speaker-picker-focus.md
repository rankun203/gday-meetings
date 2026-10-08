---
title: Focus the person search field on opening
date: 2026-10-08
status: implemented
---

## Problem

The supplied screenshot shows initial keyboard focus on the assignment scope checkbox. The picker tried to focus its search field from a task before popover presentation finished.

## Implemented solution

Declare Search people as the default focus for the picker using SwiftUI defaultFocus. Remove the task-based focus assignment. Keep normal keyboard navigation to the checkbox and other controls.

## Validation

Release build and signing passed (macOS 26 minimum, SDK 27). Diff validation passed. Visual validation is limited by the app-control permission denial in this session. Existing Command Line Tools linker search-path warnings remain.

## Technical debt

None.
