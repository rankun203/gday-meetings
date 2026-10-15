---
title: Varied transcript preview passages
date: 2026-10-15
status: ready-for-user-validation
scope: macos-preview
---

# Varied transcript preview passages

## Problem

The long transcript fixture used only two passage lengths. It did not adequately expose differences in wrapping and row-height correction.

## Implemented solution

The 10,000-segment fixture now selects from brief replies, medium passages, long paragraphs, paragraph breaks, Chinese text, and mixed Chinese/English text. A fixed numeric sequence varies neighboring lengths and reproduces the same content on every launch. Templates are initialized once. The preview guide describes the new fixture.

## Reasoning

The user's preview observation and inspection of the two-template generator establish the problem. The intended presentation retains all transcript controls and columns, with visibly varied passage heights. Repeatable data permits comparisons before and after resizing. Content is entirely synthetic.

## Technical debt

None added. The existing fixture uses fixed synthetic timestamps and silent audio; it is for layout checks, not timing or transcription-quality evaluation.

## Validation

Formatting, lint, and `make build-macos` passed in the isolated checkout. A standalone Swift inspection of the production fixture generator produced 10,000 segments spanning 14–1,444 characters, with varied neighboring lengths. Release linking retained the environment's missing Command Line Tools search-path warnings for `Developer/usr/lib` and `Developer/Library/Frameworks`; no deprecation warning was observed.

The signed bundle at `/tmp/Gday Meetings Varied Transcript Preview.app` enables the long fixture and uses a separate Preview bundle identifier, preserving the previous running Preview. Native screenshot capture remains unavailable because the computer-use service reports `Sky Computer Use native pipe startup failed`. Visual comparison must be completed in the updated Preview. Check Synthetic conversation at wide and narrow widths, on first scroll, and after resizing. No new automated tests were added for this fixture-only content change.
