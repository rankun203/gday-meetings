---
title: Center transcript timestamp hover
date: 2026-09-27
status: implemented
scope: swift-transcript-ui
---

## Problem

The supplied screenshot shows the timestamp at the upper-right edge of its hover box. The box includes the invisible width reserved for hour-long timestamps and a top-aligned 32-point hit area.

## Implemented solution

Keep the existing timestamp column and row sizing. Overlay the timestamp button at the visible label's vertical center, with six points of horizontal inset and a 32-point centered hit area. The trailing offset compensates for that inset, preserving the timestamp's original right edge. Hover feedback follows this button rather than the invisible column spacer.

## Reasoning

The supplied screenshot establishes the existing interaction state. The design changes only hover/hit geometry; timestamps and neighboring transcript text retain their positions. The existing hover modifier, tooltip, and accessible play label remain in use.

## Technical debt

None added. The existing 32-point timestamp hit height is retained.

## Validation

Passed formatting, Preview build, lint, and diff checks. Compared before/after screenshots at the same window size: timestamp right edges, text baselines, speaker columns, and row dividers stay in place. Clicked the first and second timestamps in isolated Preview; both retain accessible play labels and start silent playback at the matching time. The button bounds now follow the visible label rather than the hour-width spacer. Playback was paused after validation. System (dark) appearance checked; Light appearance, minimum-OS execution, and full keyboard traversal were not separately tested. No new tests for this reversible layout-only adjustment.

Known Command Line Tools linker search-path warnings remain, tracked in [the toolchain worklog](2026-09-25-swift-keychain-deprecations.md). No new deprecation warning was observed.
