---
title: Recording source mute
date: 2026-09-29
status: complete
scope: swift-recording
---

# Recording source mute

## Problem

The Microphone and System Audio meters had no action to exclude a source during recording. The supplied recording screenshot and isolated synthetic recording screenshot showed labels, activity histories, and level bars without hover feedback.

## Implemented solution

Each source's complete meter is a button with a minimum 44-point height, rounded hover and pressed feedback, a pointing-hand cursor, and Mute or Unmute help and accessibility labels. Muted sources show a slash symbol, “Muted,” and zero activity and level. Both sources can be changed independently; unavailable sources and finalizing recordings cannot be changed. The recording card keeps its two-column arrangement and controls do not change size on hover.

`TimedAudioWriter` serializes mute changes with audio writes. Muted capture buffers become generated silence for both the saved track and live transcription, retaining host-clock timing. This keeps live recognition coverage complete while excluding captured samples. Muting does not change the device, engine, system output volume, or other apps. Writer state survives device and voice-processing rebuilds. Resampler history resets across mute transitions, and deliberately silent recordings still count as delivered audio.

`MeetingStore` updates meter state immediately after a change. UI Preview's synthetic live recording has nonzero levels and activity history, so each source's muted and resumed appearance can be inspected without capture hardware.

## Reasoning

The writer is the shared boundary before saved audio and the live audio sink. One lock therefore controls both outputs. Stopping capture or removing a device would interrupt recovery and timing. Omitting live buffers would create false missing-coverage intervals in the speech provider; generated silence preserves continuity.

## Technical debt

None. Existing older-macOS control and audio fallbacks remain unchanged.

## Validation

- Added synthetic tests for saved and live mute silence, host-clock resume timing, device-format changes while muted, independent sources, entirely muted recordings, and semantic meter updates.
- All 455 tests passed in the integrated suite. `make format-macos`, `make lint-macos`, and diff whitespace checks passed.
- Captured the changed UI in isolated Preview. Both sources toggled independently, displayed slash symbols and “Muted,” and returned to their enabled state. The recording row and card stayed in place. Accessibility inspection prompted an explicit button trait in addition to the Mute/Unmute labels.
- The final packaged preview exposed both controls as buttons. Tab reached each source with a visible focus ring; Space unmuted Microphone and muted System Audio independently. A click in the waveform area also toggled its source. Hover and cursor use the existing action style and pointing-hand API; the automation cursor overlay prevented direct inspection of the system cursor image.
- Real microphone/system capture, device switching while muted, VoiceOver, and physical acoustic behavior require separate hardware validation. No production recording was changed.
