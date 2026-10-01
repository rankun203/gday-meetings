---
title: Review larger speaker groups
date: 2026-10-01
status: completed
scope: diarization-review-interface
---

# Problem

The review dropdown offered only nine speakers, although annotations and scoring support additional speaker IDs. Meetings with larger groups could not be labeled through the normal controls.

# Implemented solution

The dropdown now starts with Speakers 1–20. Add Speaker selects the next available number for larger groups. Existing labels from every clip and speaker reference in the sample are included when the dropdown is rebuilt, including after reload. Speaker lanes sort numerically. Number keys 1–9 remain shortcuts.

# Reasoning

An isolated preview screenshot confirmed the nine-option dropdown and available inspector space before editing. The design keeps the existing selection and assignment flow and adds a native button below the dropdown. Adding a choice does not relabel an interval; Assign Speaker remains explicit. Active review tabs and annotations are not restarted or modified.

# Technical debt

Unused added choices are temporary until assigned to an interval or saved as a reference. This avoids adding schema state for labels with no annotations. Assigned labels persist in the existing schema. No migration or new storage debt.

# Validation

JavaScript syntax and diff checks passed. In an isolated Chrome preview, assigned Speakers 20 and 21 to synthetic ranges, observed Saved, reloaded, and verified both labels remained in the annotations and dropdown. The final screenshot shows the new button and numbered lanes without overlapping controls; it is saved under ignored `tmp/diarization-review-preview-tones/speaker-count-validated.png`. Active user tabs and their annotations were not modified. Other browsers and assistive technology were not tested. No Swift code changed.
