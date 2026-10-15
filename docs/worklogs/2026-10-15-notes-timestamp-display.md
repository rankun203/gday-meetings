---
title: Notes timestamps use whole seconds
date: 2026-10-15
status: complete
scope: macos-notes
---

## Problem

The supplied recording screenshot shows fractional seconds in Notes timestamps.

## Implemented solution

Edit and Read modes display timestamps as HH:mm:ss, including leading zero hours. Fractional seconds are omitted by flooring to the containing second. The gutter reserves two hour digits and grows for longer recordings. Stored timestamp markers retain their existing precision.

## Reasoning

A separate display formatter keeps the requested readable presentation without rewriting notes or reducing playback precision. The supplied screenshot establishes the current layout; the intended layout preserves the gutter and controls with whole-second labels.

## Technical debt

None.

## Validation

The combined isolated release build passed in 121.63 seconds. Seven direct checks of the exact formatter passed, including fractional seconds, the hour boundary, multi-digit hours, and non-finite input. The synthetic preview showed HH:mm:ss labels in Edit and Read modes; the Read screenshot confirmed the full labels fit. Stored marker serialization was reviewed and remains unchanged. Existing gutter tests now assert the display formatter separately from stored markers; they were updated but not rerun. Existing Command Line Tools linker search-path warnings remain. The main library and the user’s existing preview were untouched.
