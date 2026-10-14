---
title: Native Follow Live control
date: 2026-10-14
status: complete
scope: macos-live-transcript
---

# Native Follow Live control

## Problem

The live transcript used a custom circular down-arrow button with material and a shadow. The requested design keeps the action in the bottom-right corner, with an icon only, without allocating a separate row. It must disappear while following live text.

## Implemented solution

`LiveTranscriptView.swift` presents **Follow Live** as a small native bordered icon-only button in the bottom-right overlay. Scrolling or selecting text pauses following and reveals the button. Activating it resumes following and removes the button. Its accessible name and help describe the action. Transcript issues remain available at the bottom-leading edge. The existing following and editing behavior is unchanged.

## Reasoning

Apple's current [Buttons guidance](https://developer.apple.com/design/human-interface-guidelines/buttons) and [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) favor standard controls that receive the platform's appearance and interaction behavior. [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/) explains the distinction between floating navigation controls and content, and the use of standard control sizes. Reviewed October 14, 2026.

The corner placement preserves the full reading height and the user's requested layout. Native button styling supplies focus and appearance treatment without custom blur, shadow, or hit geometry. An earlier labeled accessory row was rejected because it consumed a full row; the final design removes it. Apple permits floating controls, so the corner placement is compatible with the research rather than an exception to it.

## Technical debt

None.

## Notes

- Before-edit screenshot: isolated `tmp/source-indicators/After.app`, bundle `com.gdaymeetings.macos.preview.sourceicons.after`, synthetic live recording, Light appearance, approximately 917 × 652 points. No real capture or user recording was modified.
- Revision baseline: `tmp/source-indicators/NativeFollow.app`, bundle `com.gdaymeetings.macos.preview.nativefollow`, synthetic live recording, macOS 26.6.2, Light appearance, approximately 917 × 652 points. Captured the previous labeled accessory row before applying the user's correction.
- Scoped Swift formatting, strict lint, and `git diff --check` passed. The corrected control was captured in `tmp/Gday Meetings Test Updated.app`, bundle `com.gdaymeetings.macos.preview.corner20261014`, using the signed release build. It appears as an icon-only native button in the bottom-right corner with no accessory row. Scrolling up revealed it; clicking it returned the scrollbar to its end and removed the button from accessibility and the view.
- The broader task and transcript tests passed before this presentation-only correction and were not rerun for it. Isolated `make build-macos` passed, including signing and platform verification (macOS 26.0 minimum, SDK 27.0). Log: `/private/tmp/gday-follow-corner-release.log`. Existing Command Line Tools linker search-path warnings remain; no deprecation warnings were reported.
- This static synthetic fixture does not establish behavior during real recognition. Reduce Transparency, Increase Contrast, VoiceOver narration, and the issues popover were not separately exercised; the changed action uses a standard native button and introduces no custom material or animation.
