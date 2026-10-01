---
title: Streaming Opus recording
date: 2026-10-01
status: complete
scope: swift-app-audio
---

# Streaming Opus recording

## Problem

Swift captured full WAV tracks and converted them sequentially after Stop. An
optimized synthetic one-hour benchmark measured 19 seconds for mono and 28 seconds
for stereo Opus encoding. A 48 kHz mono microphone and stereo system track also
required about 1.04 GB of temporary 16-bit PCM per hour. The Rust client already
encoded Opus while recording, with speech tuning and DTX.

## Implemented solution

- Extend the existing C bridge with libopus speech encoding, voice signal hint,
  VBR, DTX, complexity 5, and 32 kbps per track, including stereo.
- Add a continuous Swift encoder with bounded frame/page buffers, sample-rate
  conversion with delay-compensating priming, codec lookahead, and exact final
  duration trimming. Keep DTX packets in the container so silence remains on the
  recording timeline.
- Stream Opus capture through a bounded background writer. Preserve timed gaps,
  muting, device conversion, and live-transcription input. Stop drains accepted
  audio and closes the file instead of encoding the full meeting again. Encoder
  and page-write failures remain terminal; a failed append cannot be retried or
  padded into a falsely complete recording.
- Keep WAV recording and M4A’s recoverable WAV conversion path. Reuse the speech
  encoder for explicit file-to-Opus conversions.

## Reasoning

The bundled libopus C API exposes speech and DTX controls directly. Extending the
existing static library bridge avoids a new dependency or Swift–C++ interop.
Encoding during capture addresses both stop latency and temporary disk usage;
parallel post-recording conversion would only address part of the latency.

## Technical debt

- Opus no longer retains a full PCM recovery copy. Incremental pages preserve
  encoded audio. Queue overflow still drains and closes accepted audio; a codec
  or disk-write failure closes the handle and retains only the partial file.
  Such failures or abrupt termination may leave a missing end-of-stream (EOS)
  marker or incomplete trailing page. Accepted to avoid whole-meeting WAV storage; a future repair/import path should recover
  complete pages and rebuild the final granule without claiming missing audio.
- Existing vendored Autoconf probes warn that `-single_module` is obsolete and
  reject it; actual builds do not use the flag. Refresh upstream configure scripts
  with a dependency update. Local Command Line Tools and other build diagnostics
  are recorded below after validation.

## Notes

No UI changes. Existing unrelated working-tree edits are preserved. A separate
checkout is used for release packaging so the running app is not replaced.
Hardware recording, route switching, Intel execution, and hosted CI require
separate validation; synthetic tests alone do not establish those behaviors.

The final isolated `make build-macos` release build passed
with Swift 6.4, macOS SDK 27, on Apple Silicon; packaging, Info.plist validation,
and ad-hoc signature verification passed. The first sandboxed attempt could not
launch SwiftPM’s manifest sandbox; the build ran successfully outside it.

The fresh vendor build reported obsolete `-single_module` feature probes and
upstream libtool empty-integer comparisons. Swift linking reported missing
Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search
paths, as in prior release validation. No new app API deprecations were reported.
These diagnostics remain; update the vendor build scripts with their next pinned
release and repair/update the local developer tools for the missing search paths.

An optimized standalone benchmark used the production Swift/C writer, generating
one hour per track in 100 ms chunks, alternating ten seconds of synthetic tones
with ten seconds of silence. No meeting data or full PCM files were used:

| Track | Total encoding work | Finalization | File size |
| --- | --- | --- | --- |
| Mono | 22.44 s | 0.25 ms | 8,380,659 bytes |
| Stereo | 32.23 s | 0.81 ms | 8,504,017 bytes |

Both decoded lengths were exactly 172,800,000 frames (one hour at 48 kHz). Peak
resident memory for the benchmark process was 11.3 MB. These timings measure the
encoder, not device teardown, queue backlog, live-transcript completion, or the
full app. Synthetic tone/silence sizes do not predict a real meeting’s size.
Temporary benchmark audio was removed. The C bridge’s standalone checks passed
with warnings treated as errors, AddressSanitizer, and UndefinedBehaviorSanitizer,
including configuration failures and mono/stereo DTX encoding.


The 62 focused tests across ten suites passed after the priming and terminal-error
fixes: speech/DTX, file encoders, capture timing, queue overflow, route conversion,
recording finalization, playback, conversion, capture recovery, and meeting store
integrity. Test audio readers now loop over partial reads and stop before EOF;
assertions were preserved. A stale post-stop Opus conversion test was replaced
with direct missing-WAV M4A conversion coverage. Native codec tests ran outside
the sandbox. No production audio or active recording was used.

Independent review identified and resolved two issues: uncompensated resampler
delay with `.none` priming, and padding a failed append into a falsely complete
file. The partial-write regression verifies that subsequent append/finish calls
retain the failure and do not write more bytes. The additional resampling alignment
regression passed with `.normal` priming and failed its isolated `.none` control with 44/48-frame pulse shifts and reduced
tail energy. It checks both an interior pulse and a pulse one millisecond before
the end of the recording using the production writer and decoder.

`make format-macos`, `make lint-macos`, and diff whitespace checks passed. The final
release checkout’s app sources match the validated working tree. The streaming
change was committed separately as `633372b`; unrelated Dock and logging edits
were excluded. Real device capture, acoustic quality, and Intel execution remain
unvalidated. Hosted build results are recorded below.
The built app is in `/private/tmp/gday-opus-validation.BLcLOZ/apps/client-macos-swift/.build/macos/`;
the active installation was not replaced.

## Hosted compiler compatibility

The first hosted run passed macOS 27 but failed macOS 15 and 26 because their Swift
compilers require explicit `self` for `format` inside the converter callback.
The local Swift 6.4 compiler accepted the implicit reference. The follow-up uses
`self.format`; it changes no audio behavior. The initial run is
[36811183312](https://github.com/rankun203/meeting-notes/actions/runs/36811183312).
The corrected source passed the isolated local release rebuild, packaging, and
signature verification, with the same existing Command Line Tools search-path
warnings. Formatting and diff checks passed. Hosted validation is pending the
follow-up push.
