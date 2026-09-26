---
title: Stop hidden waveform rendering
date: 2026-09-26
status: implemented
scope: swift-app-playback
---

## Problem

The waveform panel uses SwiftUI animation with completion callbacks. Its hidden track rows remained mounted after collapse, retaining playback observers and, while playing, native display links. The user reported that its current animation was smooth enough at roughly 30% CPU and requested improvements without changing behavior.

## Implemented solution

Mount individual track waveform views when opening the panel and remove them only after collapse finishes. Keep the scroll view, row controls, and equal-size placeholders mounted so scrolling position survives reopening. Keep the existing 250 ms size change, 180 ms fade and slide, full-size row geometry, focus overflow, mute controls, and shared seek timeline. Completion tokens prevent an interrupted collapse from removing reopened rows. Reduce Motion applies the mounted state immediately.

## Reasoning

Stopping hidden work preserves the established transition. No manual frame timer or new animation engine is introduced. The main playback waveform remains mounted.

## Technical debt

None added. The panel still animates layout through SwiftUI; this change does not claim to eliminate the transient CPU cost of expansion.

## Validation

Two agents reviewed the lifecycle and equal-height placeholders. Preview checks confirmed that reopening retains the muted microphone and shared playback position; track seeking updates both track timelines and the main player. Hidden track controls disappear from accessibility while collapsed and return when opened. The same checks passed with an isolated copy of the user-supplied 70-minute, two-track meeting. The full 241-test suite, formatting, lint, and Preview packaging passed. A dedicated CPU reduction measurement for this panel remains unmeasured; its existing transition timings are unchanged.
