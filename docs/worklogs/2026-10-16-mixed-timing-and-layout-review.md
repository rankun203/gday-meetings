---
title: Mixed transcript timing and window layout review
date: 2026-10-16
status: in-progress
scope: macos-transcript-and-window-layout
---

# Problem

Mixed transcripts bypassed whole-passage speaker assignment when any passage contained valid timing. Tasks and recording content could exceed the window during sidebar animation, with a transient toolbar overflow menu despite sufficient space in the settled layout.

# Implemented solution

- Extracted the existing conservative whole-passage assignment policy in `CommunityDiarization.swift` and reused it for passages without timing in `DiarizedTranscriptProjection.swift`. Timed passages still follow acoustic turns. Invalid or stale timing and manually reviewed assignments remain protected. Synthetic tests cover mixed timing, separate audio sources, ambiguity, and repeated projection.
- Bounded the main window content with `GeometryReader` before applying its 900-by-600 minimum in `GdayMeetingsApp.swift`. The navigation split receives the available window dimensions instead of propagating the window minimum through changing sidebar insets.
- Reduced Search's minimum width from 180 to 90 points at the user's request. Its ideal width remains 280 and maximum remains 360. This changes the declared bounds, but does not yet deliver adaptive toolbar sizing; see the validation limit below.

# Reasoning

The original projection work (`325a2f1`, documented in the October 14 diarization projection worklog) intended to split timed text around acoustic turns while retaining whole-passage assignment for legacy transcripts. Applying that policy per passage preserves the intent without inventing word alignment. Apple transcription requests native timing, but returned spans can be untimed or contain multiple words. Transcribing again with This Mac can improve timing coverage; it cannot guarantee every passage has timing.

The window minimum dates to `c77f7616` on September 24. A standalone synthetic SwiftUI window reproduced the clipping when content refreshed every 30 milliseconds during native sidebar animation. At a 900-point window width, the split temporarily measured 1,116 points and extended 108 points past the right edge. Removing only the root minimum eliminated the error. Keeping the minimum outside a bounded content container also eliminated it, preserving window sizing and native animation. The task progress controls are not themselves the width constraint; updates expose a pre-existing sizing interaction. The initially well-behaved copied app did not reproduce the same update workload.

At 1,100 points, the original sizing also temporarily moved the sidebar toolbar button and spacers into overflow. With the bounded container, those items stayed visible through expansion and collapse. Search still legitimately enters overflow if the entire toolbar cannot fit; reducing its minimum addresses that separate constraint. The design keeps the existing controls, toolbar maximum widths, and sidebar motion.

# Technical debt

Retained: untimed passages cannot be split safely around speaker changes. They require strong whole-passage evidence; otherwise their existing assignment remains. New transcription or a future alignment provider can supply actual timing. No new storage or schema debt. Retained: the SwiftUI custom Search toolbar item uses its fitting width instead of negotiating the full declared range. The requested adaptive Search behavior remains unresolved; a follow-up must establish supported toolbar sizing without replacing SwiftUI-owned views or using fixed window-width heuristics. The window boundary uses standard SwiftUI layout, without inspecting private view classes or overriding the native animation.

# Notes

October 19 checkpoint: the user's five-frame sequence confirms that the sidebar animation defect remains. Content translates at its previous width, the toolbar temporarily overflows, and the final frame reflows abruptly. The bounded-container results below apply only to the synthetic probe; they do not establish a complete fix or the cause of the actual animation defect. The current changes are retained as a checkpoint while independent investigations examine the full layout transition.

Before-change evidence includes the supplied screenshots, an isolated copy of the installed app, and the synthetic animation probe. All app testing uses distinct bundle identifiers and temporary synthetic libraries. No active recording or production app is operated or replaced. Diagnostic view-tree inspection exists only in temporary probes and was removed from the isolated release source before final validation.

The narrow recording waveform was separately traced to the `ViewThatFits` fallback introduced by `27e955e0` on September 26. The user confirmed widening the window restores it; no waveform change is included.

Validation:

- 32 release tests passed across diarization projection, Apple timing, local diarization, and library sidebar suites.
- Synthetic animation traces: original sizing overflowed in 20 samples (maximum 108 points); removing the minimum and bounding the content each had zero overflowing samples. Bounded expansion and collapse were each sampled 1,000 times. At 1,100 points, bounded Meetings toolbar traces had no transient hidden controls; the original had seven samples with the sidebar button hidden.
- Final isolated `make build-macos-preview` (including `make build-macos`) passed, including minimum-platform and signing checks. Scoped Swift formatting and `git diff --check` passed.
- Captured and inspected the fixed full-app recording and Tasks layouts with synthetic data, sidebar expansion/collapse, and window resizing. The animation stress comparison uses a standalone reproduction rather than the user's live workload. Existing sidebar tests do not reproduce all SwiftUI scene-toolbar behavior.
- Search validation limit: a 90-to-360-point frame still presents a 280-point fitting width to the native toolbar. Lowering its ideal size to 90 makes it visible at narrower widths but leaves it small after expansion. Native compression priorities, size proposals, Auto Layout bounds, and automatic toolbar placement did not establish the requested adaptive behavior in the temporary probe. Those experimental changes are not in the repository. The declared minimum reduction alone must not be described as a complete resizing fix.
- Existing linker warnings reference absent `/Library/Developer/CommandLineTools/Developer/usr/lib` and `/Library/Developer/CommandLineTools/Developer/Library/Frameworks`. No new source deprecation warnings were observed. No push was performed, so CI was not run.

No change has been installed or published. Temporary traces and the reproduction source are under `/tmp/gday-animation-*`; the isolated checkout is `tmp/regression-review-20261016`.
