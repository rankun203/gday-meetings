---
title: Remove the empty live transcript controls row
date: 2026-10-08
status: implemented
---

## Problem

Removing the transcription switch left a dedicated row with a disabled Follow Live button. The supplied recording screenshot shows the resulting gap between recording options and transcript text.

## Implemented solution

Move transcript controls into a bottom overlay. Show Follow Live only when text exists and following is paused. Use a circular floating arrow-down-to-line icon with a Follow Live tooltip and accessibility label; activating it resumes following and hides the button. Keep transcript issue details accessible without reserving a header row. Following, scrolling, and editing callbacks remain unchanged. A follow-up screenshot exposed another 24 points of stacked spacing: the recording panel’s bottom padding and the detail stack’s section spacing. Remove the bottom padding and group recording controls with meeting content at zero spacing during capture. Preserve header spacing and saved-meeting section spacing.

## Validation

Release build passed using a separate app output path; the active recording was left running. Diff validation passed. An isolated synthetic preview was prepared, but computer-use permission denied access, so the after-change screenshot and scroll/follow interaction remain unverified. The preview bundle was removed. The prior diarization commit passed both macOS CI runners. The build emitted existing missing Command Line Tools linker search-path warnings.

## Technical debt

None.
