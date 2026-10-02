---
title: Recording meter animation
date: 2026-10-02
status: complete
scope: swift-recording-ui
---

# Problem

The microphone and system audio level bars jumped between values. Capture already publishes meter levels every 100 ms, with 20 ms timer leeway, but the native bar disabled layer animations. Increasing the publication rate would add work without addressing presentation between samples.

# Implemented solution

`RecordingActivitySurface.swift` animates each bar's width over 100 ms with a linear Core Animation transition. Each update starts from the displayed width and replaces the previous animation. Capture processing and publication rates stay unchanged. The bar keeps its existing native view and direct meter subscription, avoiding per-frame SwiftUI updates and additional application timers.

Unavailable, muted, stale, reconnecting, and finalizing sources clear immediately. Reduce Motion uses immediate updates. Hidden or occluded windows do not start animations; dismantling the view cancels its animation. Accessibility values continue to report measured levels. Regression tests cover unavailable states, Reduce Motion, and teardown cancellation.

# Reasoning

The supplied recording screenshot established the affected bars. The intended design preserves their layout and colors while interpolating width between samples. Core Animation supplies display frames without an application display-link callback. Reading the presentation layer before retargeting avoids jumps during interrupted transitions. A left-anchored width change preserves the rounded ends.

The user approved the animated version after comparing labeled original and animated bars with recorded microphone and system audio. The comparison used a private temporary app; no source audio, recording identifiers, or derived samples were added to the repository.

# Technical debt

None. No new timer, dependency, compatibility bridge, or change to audio measurement semantics was introduced. Validation limits below remain measurement follow-ups rather than implementation shortcuts.

# Validation

- Standalone compilation succeeded. The combined sequential suite passed 632 tests in 109 suites, including meter regressions. Formatting, lint, and diff whitespace checks passed. The isolated release build succeeded in 130.63 seconds with plist and signature validation. Existing Command Line Tools linker warnings report absent Developer library/framework search directories; no deprecated API warnings were observed. The final synthetic recording preview showed the production meter surfaces and renamed recording controls.
- A temporary AppKit comparison confirmed intermediate presentation widths while animations were active. Both versions received identical inputs at 10 Hz. The recorded-audio comparison used the latest complete 60-second excerpts, silently repeated, with RMS calculated over 100 ms windows. Production reads the latest capture-buffer measurement, so this comparison establishes presentation behavior rather than exact production meter trajectories. The running recording was preserved.
- Four visible eight-second CPU runs measured original, animated, original repeat, and animated repeat at 0.784%, 0.226%, 0.152%, and 0.387% of one CPU core. The runs delivered 79, 81, 81, and 81 updates respectively. Warmup and noise prevent a claim that animation is faster. The warmed pair showed about 0.24 percentage points of additional process CPU. Visibility was checked at phase endpoints, not continuously; GPU cost, energy use, and long-duration behavior were not measured.
- An earlier comparison used a run loop that did not process normal AppKit visibility events. Animations remained disabled, so its CPU results were discarded. The corrected comparison used the AppKit application event loop and verified active interpolation before performance conclusions.

Future performance investigation should compare longer visible runs, record visibility throughout, and measure compositor and energy use if those costs become material. Current evidence supports inexpensive process-side interpolation without establishing a battery-life estimate.
