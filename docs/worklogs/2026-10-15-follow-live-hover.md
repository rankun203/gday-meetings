---
title: Follow Live overlay feedback
date: 2026-10-15
status: complete
scope: macos-live-transcript
---

# Follow Live overlay feedback

## Problem

The bottom-right Follow Live button blended into transcript text and selected rows. Its native bordered style provided little visible hover feedback.

## Implemented solution

`LiveTranscriptView.swift` retains the small native bordered button and adds an opaque, appearance-adaptive background beneath its bezel. A subtle foreground overlay changes on hover, with an additional outline when Increase Contrast is enabled. The native button retains pressed and keyboard-focus feedback, its icon-only label, tooltip, and accessibility label.

The button occupies the same bottom-right overlay bounds. It remains absent while following live text and resumes following when activated.

## Reasoning

Before editing, inspected the supplied screenshot and captured the isolated People Review preview with `--synthetic-live-recording`, after scrolling up. The small gray button remained visible over the transcript with no separate row. The design keeps that layout and adds a solid surface and hover feedback without introducing a new control style or changing transcript scrolling.

## Technical debt

None.

## Validation

- Scoped Swift formatting lint passed.
- Reviewed surrounding wording against the writing guide; no UI text changed.
- Isolated release build passed. Captured the changed synthetic preview: the opaque icon-only control remains at the bottom right without a separate row. Clicking it returned the transcript to its bottom and removed the control from the accessibility tree. The installed app and its active recording were not changed.
- Hover state wiring was code-reviewed. The available native UI automation does not expose pointer movement, so hover and Increase Contrast appearance were not captured interactively.
- The pre-change preview uses synthetic content and silent playback. It does not validate real recording or recognition behavior.
- Final isolated release build and combined release regression run passed (61 tests in 7 suites). Two existing linker warnings remain for missing Command Line Tools search directories (`Developer/usr/lib` and `Developer/Library/Frameworks`); no deprecated API warnings appeared. Toolchain-path cleanup remains a separate environment maintenance item.
