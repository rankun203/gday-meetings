---
title: Meeting language picker width
date: 2026-09-28
status: validating
scope: swift-meeting-header
---

# Meeting language picker width

## Problem

The supplied screenshot shows **Chinese (Sim…)** despite available header space. The compact native picker had a fixed 120-point width. The Speakers description also included an unnecessary reassurance sentence.

## Implemented solution

Size the compact picker from the selected language's native control-font width plus menu padding, bounded between 80 and 280 points. Keep the native picker and information button. The existing narrow header layout stacks the language control below the date when they do not fit side by side. Remove “You can change any match.” from the Speakers description.

## Reasoning

The selected name determines the space needed without reserving a large field for short names. The cap prevents unusually long labels from taking over the header. Existing native menu, accessibility, and language-code behavior remain unchanged.

## Validation

Inspected the supplied 12:54 screenshot before editing. Parent agent will verify the long selected language in the rebuilt Preview and include the change in consolidated build/lint validation. No behavior-mirroring test added for this sizing-only change.

The rebuilt Preview displayed Chinese (Simplified) in full at the normal meeting-detail width. The native language menu changed the selected value correctly. The speaker guidance source no longer contains the redundant final sentence.

## Technical debt

None introduced. The width uses the native default control font and a fixed allowance for native menu chrome; visual validation remains necessary when changing the control size or typography.
