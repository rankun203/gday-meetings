---
title: Align General settings pickers
date: 2026-10-22
status: validated
scope: swift-app-settings
---

## Problem

Compact dropdowns followed their labels directly, while switches aligned with
the trailing edge of the column.

## User Intention

Right-align dropdowns on the General settings page and place each capability
provider dropdown on the same row as its label.

## Implemented solution

General settings aligns Default Language, Audio Format, and Appearance to the
trailing edge. Labels stay on the leading edge. The language information button
sits beside its label, allowing all dropdown edges to line up. Native pickers
retain their natural widths. Provider controls now share a row with their labels,
with a maximum width of 200 points to leave room for those labels. Long selected
names truncate; their full values remain accessible and visible in the popover.
Readiness messages and repair links remain below the row.

## Reasoning

Inspected the supplied screenshot and captured the running General screen before
editing. The installed app showed the older language section; the supplied
screenshot and current source establish the new Default Language row. The design
retains native controls, bindings, accessible picker titles, and information help.
Only visible embedded picker labels are hidden to avoid repeating the row label.
The shared language picker opts into this layout only for General settings; its
other callers retain their existing layout.

## Technical debt

None.

## Notes

- Formatting and lint passed. Isolated release build, platform checks, signing,
  and Preview packaging passed. Claude Code Opus 5.5 found no blocking issues
  after the refinement.
  The first review identified the language accessory offset and possible picker
  expansion; both were addressed. Labels retain their full height when wrapping.
  Kept the existing provider-label font and accessibility pattern. Full provider
  names remain available in the existing selection popover.
- Captured and inspected final light/dark screenshots in the standard synthetic
  Preview at `/tmp/gday-recording-language-validation`, built from the scoped
  working diff over revision 486fb97 plus the preceding language changes. Used
  a unique Preview bundle identifier; the full app stayed running.
- Verified all five provider rows, readiness messages below their row, provider
  popover open/dismiss, the language information popover, Audio Format selection
  using End/Return, scrolling to Appearance, and selecting Dark. Accessible names
  and values remain present. The fixed 960-point Settings width fits all labels.
- Release validation used macOS 26.6.2 with SDK 27.0 and a macOS 26 minimum.
  Existing toolchain warnings report missing Command Line Tools library/framework
  search paths. No deprecation warning was observed.
- No new tests were added for this layout-only change. Real capture, disabled
  recording controls, and a live VoiceOver session were not exercised.
