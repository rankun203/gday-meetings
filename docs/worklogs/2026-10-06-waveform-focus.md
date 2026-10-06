---
title: Waveform keyboard focus
date: 2026-10-06
status: complete
scope: macos-playback
---

## Problem

Clicking or dragging the playback waveform requested keyboard focus and left a blue border. SwiftUI also enabled click-to-edit focus independently of the gesture handler.

## Implemented solution

Removed the pointer gesture's focus assignment in `WaveformTimeline.swift`. Set its focus interactions to `.activate`, so keyboard navigation can reach the waveform without clicks requesting editing focus. The native drawing and scroll views contain no focus requests. Layout and interface wording are unchanged.

## Reasoning

Use SwiftUI's supported focus interaction API rather than clearing another control's focus after each seek or hiding a border while retaining pointer-acquired focus. The keyboard focus indicator remains available for arrow-key seeking.

## Technical debt

None.

## Notes

Inspected the supplied screenshot and captured the running app before editing. Compared screenshots in an isolated synthetic probe using the changed waveform, native drawing view, and scroll view: clicks and drags changed the position without moving focus from a text field or showing a waveform border. Tab reached the waveform; Right Arrow advanced five seconds; Tab and Shift-Tab moved focus away. An accessibility adjustment changed the position without moving keyboard focus. Automated horizontal scrolling did not change the position, so live trackpad panning remains a validation limit.

`make build-macos` passed in an isolated copy, targeting macOS 26.0 with SDK 27.0, with bundle signing verification. No deprecation warnings appeared. The linker reported two missing Command Line Tools search directories (`Developer/usr/lib` and `Developer/Library/Frameworks`); linking and signing succeeded. These environment warnings remain, with toolchain path configuration investigation as follow-up. All six waveform scroll and lifecycle tests passed using the repository's explicit Swift Testing plugin workaround after default plugin discovery failed. Swift formatting and diff checks passed. The running app and its active processing were preserved; this change has not been installed into that running bundle. No commit or push was requested.
