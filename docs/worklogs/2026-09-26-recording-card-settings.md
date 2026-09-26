---
title: Compact recording card settings
date: 2026-09-26
status: implemented
scope: swift-app-recording-ui
---

## Problem

The date, language, tags, and microphone processing controls used too much space during recording and split related settings across the meeting header and recording card.

## Implemented solution

During recording, the meeting header keeps the title. The card shows the date, recording state, timer, Stop & Save, and both source meters. A full-width native button with a 44-point minimum height reveals Language, Voice Processing, and Tags. Its folded summary includes every current setting. The processing summary uses semantic availability state rather than matching device-fallback messages. Changing language restarts live recognition while preserving finalized earlier phrases.

## Reasoning

Keep stop/status controls visible while moving less frequent settings into one accessible disclosure. Reuse existing native controls and tag actions. Respect Reduce Motion; hover and focus do not alter layout.

## Validation

Preview checks passed in dark and light appearances at approximately 903 × 652 points. The folded summary remains visible, both source names remain readable, and Language, Voice Processing, and Tags are reachable together in the settings scroll area. Stop, timer, source meters, and the notes editor remain visible. Tag changes update the folded summary. The card reserves 230–330 points of height and uses a compact header so the settings viewport cannot collapse. The full 241-test suite passed before the final layout-only refinement; 18 focused meter/live tests, formatting, lint, and packaging passed afterward. The complete keyboard navigation matrix remains untested.

## Technical debt

None. Real recording device/processing transitions still require the existing hardware validation matrix.
