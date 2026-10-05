---
title: Sidebar motion review
date: 2026-10-05
status: complete
scope: swift-app-ui
---

# Sidebar motion review

## Problem

The sidebar transition feels linear or slow. Distinguish the system's animation curve from missed frames caused by content layout before changing motion.

## Findings and intended behavior

Production `GdayMeetingsApp` constructs `LibraryView()` without a diagnostic sidebar control. Its toolbar uses the sidebar toggle supplied by `NavigationSplitView`; the app does not override the toggle's animation curve. The private `toggleSidebar(reduceMotion:)` method is connected only to the optional performance-test driver. Changing that method's curve would not change the visible toolbar action.

Keep the native sidebar transition, toolbar placement, selection, and immediate reversal. Respect the system Reduce Motion preference. Investigate expensive layout during resizing as a separate performance issue; replacing easing cannot remove main-thread stalls.

## Official guidance

Reviewed October 5, 2026:

- [Apple HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion) recommends system motion, brief and precise feedback, and allowing interaction before animations finish. System components adapt motion to accessibility and input methods. It does not prescribe a custom spring for macOS sidebars.
- [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) supplies its own sidebar toolbar control and supports column visibility bindings. The existing production hierarchy already uses this supported component.
- [Animation.default](https://developer.apple.com/documentation/swiftui/animation/default) is a critically damped spring on macOS 14 and later, with response 0.55 and damping fraction 1. The diagnostic driver already uses this default; it is not linear.

The Motion page was read through Apple's DocC JSON; API pages were read through Apple's linked Markdown representations after the browser fetch rejected their content type.

## Reasoning

Retain the system transition unless frame-level evidence establishes a specific application defect and a supported fix. A custom toolbar button or decorative bounce would replace working platform behavior without addressing layout cost. Existing sidebar CPU tests are useful for visibility/reversal checks but use a programmatic transition; they do not measure the exact native toolbar action or establish visible frame pacing.

## Implemented solution

The current Time Profiler review found 5.303 seconds of sampled main-thread work in layout, out of 8.193 sampled seconds. Transcript settling accounted for 839 milliseconds inclusively; text height measurement accounted for about 300 milliseconds. These are cumulative samples, not one sidebar toggle's duration. Longer run-loop spans also include meeting selection, so they do not prove a particular click caused a stall.

`TranscriptHeightCache` now retains the native unwrapped text bounds alongside its existing per-row entry. For single-paragraph text that fits completely at the current width, resizing reuses the exact native height. Near the wrapping boundary and for wrapped text, the original native measurement remains in use. Explicit line breaks bypass the fast path. The same font and bounding-rectangle options determine both paths. Cache entries remain bounded by the active transcript rows and invalidate when text changes; existing row removal clears the additional metrics too.

The design preserves live wrapping, row positions, viewport anchoring, editing, and playback following. It removes repeated sizing work without delaying reflow, estimating row heights, changing the animation curve, or moving AppKit operations off the main thread. Long wrapped rows incur one extra initial unwrapped measurement; later constrained measurements retain the existing behavior.

## Technical debt

Retained: sidebar resizing can trigger expensive content reflow, previously documented in the September 26 sidebar worklog. Changing the animation curve does not resolve this. Use the current Time Profiler capture to identify repeated application layout work, then validate a targeted reduction against native toggles and long synthetic content. Frame-level visible validation remains necessary before claiming smoother animation.

## Validation

Source and historical worklog review complete. Captured the existing expanded native sidebar and synthetic Transcript in dark appearance before editing, using Preview `40e64af-responsiveness-ui` at `apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`. Meeting selection and paused playback remained intact after switching to Transcript and expanding the sidebar. Settled screenshots do not establish animation frame pacing.

All 37 targeted tests passed across `NativeTranscriptTests`, `LiveNativeTranscriptTests`, `WaveformScrollTests`, and `WaveformScrollLifecycleTests`. Fitting Latin, CJK, Arabic, emoji, empty, and tab-containing synthetic rows required one native measurement across 401 distinct widths, down from 401 (99.75% fewer calls). Exact native-height comparisons passed at quarter-point increments around each wrap boundary, across wrapped text and explicit newline variants, and after text changes. This is a deterministic work-count improvement, not a measured whole-animation latency claim.

The first test run passed the new measurement checks but exhaustive repeated native oracle calls delayed an existing hover-timer assertion. Reducing redundant oracle work retained boundary coverage; the entire targeted group then passed. No application timing workaround was added. Formatting and diff whitespace checks passed; successful Xcode-toolchain test compilation reported no warnings.

The final combined release build (`40e64af-sidebar-review`) passed in 150.76 seconds without warnings; formatting and lint passed. Post-change Preview screenshots in light and dark appearances show the synthetic transcript wrapping correctly with the sidebar expanded and returning to single-line rows when collapsed. Meeting selection and paused playback position survived toggles, including consecutive keyboard toggles.

Limits: screenshots show settled layout, not frame pacing. No post-change Time Profiler comparison or physical high-frame-rate capture was made. Reduce Motion, inactive-window transitions, and mid-frame reversal were not rechecked in this UI pass. No animation curve change made.
