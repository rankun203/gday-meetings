---
title: Transcript leading whitespace
date: 2026-09-27
status: complete
scope: macos-transcript-ui
---

## Problem

The supplied screenshot and running app show a space before the first word of transcript rows. Accessibility inspection confirmed that the space is in the text value, rather than the row layout.

## Implemented solution

The saved transcript editor omits leading whitespace when reading each segment into its text field. First and wrapped lines share the same leading edge. Timestamp spacing and editing controls stay in place.

## Reasoning

Removing the text prefix addresses the cause without changing column spacing. Existing saved transcripts and live checkpoints receive the same presentation. Trailing and internal spaces remain available while editing; original stored text is preserved until edited.

## Technical debt

None.

## Notes

Captured the existing screen before editing and the changed isolated Preview afterward. Pasting a wrapping paragraph with two leading spaces displayed no leading spaces; first and wrapped lines aligned. Editing and Tab navigation passed. Formatting, lint, diff whitespace checks, and the production/Preview build passed. Dark appearance, narrow windows, and real playback were not retested for this text-only change. The installed app was not replaced.

The build reported two linker search-path warnings for absent Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` directories. No API deprecation warnings appeared. These toolchain warnings did not prevent linking or signing; toolchain search-path cleanup remains outside this change.
