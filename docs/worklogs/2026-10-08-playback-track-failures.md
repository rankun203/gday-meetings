---
title: Continue playback when an audio track fails
date: 2026-10-08
status: complete
scope: macos-playback
---

## Problem

One unreadable audio track stopped preparation of the entire meeting. The expanded player had no way to identify the failed track.

## Implemented solution

The streaming transport retains each track's original index and records preparation, opening, seeking, and decoding failures separately. Failed tracks leave the audible mix; surviving tracks keep their shared clock and controls. A global error remains when every track fails. The player exposes failures beside their track names with a yellow warning, accessible error details, and “Audio unavailable” in place of the waveform. The track picker lists playable tracks; failed rows cannot be unmuted. Muting the only healthy track no longer selects the failed track. Cached waveforms cannot overwrite the prepared audio duration after loading finishes.

## Reasoning

The existing expanded-player screenshot showed aligned track names, mute controls, and waveforms. Preserve those rows and transport controls, placing the warning beside the affected name. Excluding failed tracks from the mix also avoids reducing the remaining audio's volume. Preserve explicit mute choices rather than automatically unmuting another track.

Use synthetic invalid audio in tests and the optional `--preview-unavailable-track` UI preview. Original recordings remain untouched.

## Technical debt

None.

## Notes

- All 20 tests in `MeetingPlaybackTests` and `StreamingPlaybackTests` passed in the release configuration after the final correction. Coverage includes preparation and decoder failures, failures during seeking and reading, all-track failure, stable track indices, mute selection, cleanup, and real offline audio output without volume loss.
- Before and after screenshots were inspected in isolated synthetic previews. Verified the yellow warning and accessible error, the disabled failed-track mute control, the healthy waveform, continued All Tracks playback, seeking, pause, mute/unmute, and a picker containing only playable tracks. The final screenshot shows playback advancing with the warning present and no global error.
- Light, Dark, and System appearance passed. Keyboard Tab skips the unavailable mute control, Space controls playback, and Right Arrow seeks the healthy waveform by five seconds with visible focus. Playback continues through sidebar expansion. Default and zoomed window layouts passed in active and inactive states. Minimum-width layout, VoiceOver speech, and accessibility preference overrides were not exercised; no custom material or animation was added.
- Capture provenance: `/tmp/Gday Track Failure Final Preview.app`, executable built October 8 at 15:37 AEDT, macOS 26.6.2, Swift 6.4, SDK 27.0, with `GdayUIPreview` and `GdayUnavailableTrackPreview` enabled. Source is base `15d4513` plus `/tmp/gday-track-failure-source.patch` (SHA-256 `29cf604ec380e3b94c4a55da3a3e76f77d5bcc5b39857525688cacd44d4454df`). The six source/test files match the main checkout. `make format-macos` and `make lint-macos` passed in the isolated checkout.
- The final `make build-macos` release build, platform check, packaging, and signature verification passed in `/tmp/gday-track-failure-validation`. Validation is local to Apple silicon; no Intel or CI runner was exercised.
- Existing Command Line Tools linker warnings reference missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths. They are not deprecations and were not suppressed; toolchain remediation remains tracked in [the existing worklog](2026-09-25-swift-keychain-deprecations.md). Existing audio fixtures also emit an AVAudioFile diagnostic about ignoring non-interleaved file settings.
- The automatic UI approval review blocked selecting an unrelated real meeting; inspection continued in the isolated silent preview. Existing unrelated work in the main checkout is excluded from the isolated build. User recordings were not modified or replayed during validation.
