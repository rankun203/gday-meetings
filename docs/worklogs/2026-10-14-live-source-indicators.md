---
title: Live transcript source indicators
date: 2026-10-14
status: complete
scope: macos-transcript
---

# Live transcript source indicators

## Problem

Live transcript rows retained audio-source metadata but hid it, making microphone and system-audio passages indistinguishable.

## Implemented solution

- Carry the typed source into native display rows, including completed and provisional paragraphs.
- Show a microphone or speaker symbol between the timestamp and text. Reuse the saved transcript palette: microphone slot 0 (teal), system-audio slot 1 (pink), with the existing tinted badge background and appearance-aware foreground.
- Include source tooltips and accessibility labels. Reserve a 32-point source column in both native layout and text measurement; saved transcript layouts keep their existing columns.

## Reasoning

The supplied screenshot and an isolated synthetic recording Preview confirmed that timestamps led directly into text. Compact source symbols restore attribution without using the wider person-name column. Source color remains independent of detected speaker identity and provisional-word highlighting.

## Technical debt

None.

## Validation

- Baseline: production components in an isolated copy of the existing development bundle, launched with `--synthetic-live-recording`. Captured and inspected the live state before editing.
- Source: `749fe6e` plus the three UI file changes for this task. Validation checkout: `/private/tmp/gday-source-indicators`.
- Environment: macOS 26.6.2, Swift 6.4; release build targets the repository's macOS 26 minimum.
- Formatting, lint, and diff whitespace checks passed. All 38 tests in LiveNativeTranscriptTests, LiveTranscriptDisplayCacheTests, LiveTranscriptStreamDisplayCacheTests, NativeTranscriptGeometryTests, and TranscriptLayoutServiceTests passed.
- `make build-macos` passed in the isolated checkout (305 seconds); bundle signing and platform verification passed (macOS 26.0 minimum, SDK 27.0). Logs: `/private/tmp/gday-source-indicators-build.log` and `/private/tmp/gday-source-indicators-tests.log`.
- Build warnings: copied Swift build metadata referenced stale original-checkout paths; rebuilding regenerated those outputs. Both builds also reported missing Command Line Tools linker search directories (`Developer/usr/lib` and `Developer/Library/Frameworks`). These are toolchain environment warnings; no deprecation warnings were reported.
- Changed UI: `tmp/source-indicators/After.app`, debug binary built October 14 at 13:07 local from this source diff, `--synthetic-live-recording`. Captured and compared System, Light, and Dark appearances at 1200 × 800 points and a resized window around 917 × 652 points. Source badges align with timestamps and first text lines; long text wraps without overlap. Native accessibility exposes each source name. Keyboard Return opens editing, Escape cancels, and scrolling/Follow Live preserve the icons.
- Real recognition, VoiceOver speech, increased contrast, and hour-long timestamps were not manually exercised. No new timestamp geometry or animation was introduced.
- No real recording, provider request, or hardware playback is used for validation.

Apple API references checked: [SF Symbol images](https://developer.apple.com/documentation/appkit/nsimage/init(systemsymbolname:accessibilitydescription:)) and [image tint](https://developer.apple.com/documentation/appkit/nsimageview/contenttintcolor), supported since macOS 11 and 10.14 respectively.
