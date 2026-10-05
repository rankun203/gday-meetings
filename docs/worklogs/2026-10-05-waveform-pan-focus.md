---
title: Preserve keyboard focus during waveform panning
date: 2026-10-05
status: complete
scope: swift-app-ui
---

# Preserve keyboard focus during waveform panning

## Problem

Horizontal waveform scrolling explicitly assigned keyboard focus on every scrub update. Two-finger panning therefore moved focus and displayed the waveform's blue focus border.

## Design and evidence

Reviewed the supplied screenshot and captured the existing synthetic Preview player before editing. The dark Preview used the `40e64af-summary-instructions` build at `apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`, with silent playback and synthetic fixtures. The source confirmed that the scroll callback set `focused = true` independently of seeking.

Keep the waveform layout and playback feedback unchanged. Panning changes playback position while preserving the current keyboard focus. Existing click/drag focus, Tab navigation, arrow-key seeking, and accessibility adjustment remain available. A waveform that already has keyboard focus keeps its visible focus indicator.

## Implemented solution

`WaveformTimeline` passes its scrub callback directly to `WaveformScrollInput`, removing the scroll-specific focus assignment. Compact and expanded track waveforms share this component.

## Reasoning

Focus and playback position are separate interaction states. Removing the explicit focus transfer fixes the cause without hiding focus indicators or disabling keyboard access.

## Technical debt

None.

## Validation

- Reviewed surrounding text against the writing guide; no UI wording changed.
- Before capture inspected the synthetic compact waveform in dark appearance. Automated horizontal scroll input did not change playback position, so it did not reproduce a physical trackpad gesture. Source inspection and the supplied screenshot establish the focus transfer.
- Both waveform scroll suites passed in the integrated targeted test run. The final combined release build (`40e64af-sidebar-review`) passed without warnings; formatting and lint passed.
- Post-change synthetic Preview screenshots verified the waveform keeps a visible keyboard focus border, Shift-Tab moves focus to Forward 15 Seconds, Tab returns to the waveform, and Left Arrow changes 0:35 to 0:30 while paused. Ordinary waveform clicking still acquires focus and seeks. Light and dark screenshots show the waveform without a border when another control has keyboard focus.
- Automated horizontal scroll still did not advance playback; it left focus on the transport button. This does not verify a physical two-finger gesture. Physical panning, expanded-track keyboard traversal, and accessibility preference variants were not rechecked in this pass.
