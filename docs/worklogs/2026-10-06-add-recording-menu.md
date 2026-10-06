---
title: Recording action in the Add Meeting menu
date: 2026-10-06
status: complete
scope: swift-app-ui
---

# Recording action in the Add Meeting menu

## Problem

The plus control suggests meeting creation, but its menu offered only media import and notes. People looking there for recording setup had to find a separate control.

## Implemented solution

Add “New Meeting Recording…” as the first native menu item, with a recording symbol. It opens the existing recording setup sheet and uses `canStartRecording` to prevent another recording during capture, transitions, saving, or unavailable library writes. Update the UI design contract.

## Reasoning

The existing setup flow already handles meeting titles and sources. Reusing its presentation state avoids a second recording path. The longer menu label makes the creation choice explicit alongside “New Meeting Notes”. Other recording entry points retain their established labels.

## Technical debt

None.

## Notes

Inspected the existing synthetic preview and the supplied menu screenshot before editing. The design adds one first-row action without changing the toolbar layout or the remaining menu actions. Formatting and lint passed. An isolated `make build-macos` release build passed with macOS 26 minimum and SDK 27, including packaging and signature verification. The initial relocated cache produced stale-path warnings, and Command Line Tools reported missing developer library/framework search paths; no deprecation warnings were reported. Incremental release/preview packaging passed without warnings. The original running preview remains untouched. Existing unrelated workspace changes are preserved.

In the rebuilt Light preview (`recording-menu-dirty`), accessibility inspection confirms the recording action is first, followed by import and notes. Pointer activation and Home/Return keyboard activation both open the existing setup sheet. Escape cancels without changing the two-meeting library. Captured and inspected the changed library and setup sheet: toolbar and sheet layout remain stable. The native menu popup is absent from the app-only screenshot, so its order and label were verified through accessibility rather than screenshot pixels. Dark appearance, active-recording disabled states, real capture, and hardware permissions were not exercised. No commit or push was requested, so CI matrix checks were not run.
