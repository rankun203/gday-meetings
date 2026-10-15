---
title: Complete Notes timestamps
date: 2026-10-15
status: complete
scope: macos-notes
---

## Problem

The Notes editor used a 46-point timestamp button and a 52-point text inset. Native button padding left too little space for hour timestamps and fractional seconds, causing an ellipsis.

## Implemented solution

Measure the native timestamp button with its actual font, reserving two-digit hours and fractional seconds. Use the same width for all timestamp buttons and the text inset. Longer hour values expand the gutter using timestamp information collected during the existing cached line-index pass. Width measurement runs only when the hour digit count changes.

## Reasoning

An isolated synthetic Notes screenshot confirmed the gutter alongside text and image previews before editing. The intended design preserves the existing font, playback action, and shared text/image alignment while showing the complete timestamp. Reserving hour space avoids shifting notes when a recording crosses one hour. No timestamp data or formatting changes are needed.

## Technical debt

None introduced. The existing shared Notes editing state and unconditional layout requests remain outside this visual fix; responsiveness requires separate implementation and measurements.

## Validation

Added native layout coverage for minute, hour, fractional-second, and three-digit-hour timestamps, plus stable alignment at the one-hour boundary. Scoped strict formatting and diff checks passed. The parent validated an isolated release build (230.75 seconds); two existing missing Command Line Tools linker paths remain. Six test functions across three suites passed in 9.652 seconds: seven timestamp-gutter cases, three line-index tests, and two hosted-editor layout cases.

Captured the rebuilt Notes Review synthetic preview during recording and after stopping it. The parent independently inspected the changed screen. Hour values with and without fractional seconds display fully, including `1:02:03.4`, `12:34:56`, and `12:34:56.7`. Text and both image previews share the same left edge. Timestamp buttons remain disabled during recording; afterward, choosing `0:30` started silent playback at `0:27`, preserving the existing three-second lead-in. Playback was paused and the preview left on Notes.

Synthetic timing comments were seeded through the preview's temporary `notes.md` file. Stopping the synthetic recording later displayed a meeting-changed-on-disk notice; its cause is under separate investigation, so this check does not establish a clean stop/save path. No main-library files or active user recording were accessed or modified.

The final combined regression exposed a fixture expectation at `359999.96` seconds: marker serialization rounds it to `100:00:00`, while the assertion formatted the original unsaved value. The native gutter correctly displays the stored timestamp. The fixture now derives its expected display from the serialized marker, preserving the existing marker precision and UI behavior. The focused suite passed all three test functions, including six timestamp cases, in 0.187 seconds.
