---
title: Short provider speaker labels
date: 2026-09-27
status: implemented
scope: macos-speaker-presentation
---

## Problem and design before implementation

The supplied transcript screenshot shows `mic_SPEAKER_00` wrapping across two lines. Display exact microphone and system provider labels as `mic_00` and `sys_00` throughout the Swift interface. Keep assigned person names, unfamiliar labels, stored provider identifiers, recognition associations, and export data unchanged.

## Implemented solution

A presentation formatter accepts only the exact `mic_SPEAKER_` or `sys_SPEAKER_` prefix followed by ASCII digits. Transcript fallback labels opt into this formatting; Speakers rows and their assignment accessibility labels use the same formatter. Person names bypass it.

## Reasoning

Shortening only known provider tokens prevents broad string replacement from altering names or IDs used by recognition and persistence.

## Validation

Formatting and lint passed. All 313 tests passed, including compact-label mapping, unfamiliar-label preservation, assigned-name preservation, and unchanged canonical labels/associations. The production build passed (38.04 seconds). Existing Command Line Tools missing-search-path linker warnings remain; no new deprecated APIs were introduced. The UI audit found no remaining legacy raw-speaker picker or alternate display path. Native visual checks are deferred while the user is interacting with the app.

## Technical debt

None.
