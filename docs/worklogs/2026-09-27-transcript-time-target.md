---
title: Transcript timestamp target
date: 2026-09-27
status: implemented
scope: macos-transcript-ui
---

## Problem and design before implementation

The supplied screenshot highlights a timestamp whose clickable area is limited to the digits. Make the entire existing hour-capable gutter clickable, including its blank left space, with a minimum 32-point height extending below the first text line. Keep timestamps right aligned and top aligned with the transcript text. Add subtle hover feedback while preserving native keyboard interaction. Nonactionable timestamps remain plain text.

## Implemented solution

Move the shared-width timestamp layout inside the native button label. Use the app's existing hover modifier with a borderless native button. The timestamp format, speaker and text columns, seek action, and unavailable-playback behavior remain unchanged.

## Reasoning

The hit target follows the visible column instead of an overlay around only the digits. A minimum height makes short rows easier to click without adding padding to every side or shifting text downward.

## Validation

Formatting and lint passed. All 313 tests passed, including existing timestamp format checks. The production build passed (38.04 seconds). Existing Command Line Tools missing-search-path linker warnings remain; no new deprecated APIs were introduced. Native hover, keyboard focus, and full-gutter hit testing have not been visually checked; the user’s active app is left untouched.

## Technical debt

None.
