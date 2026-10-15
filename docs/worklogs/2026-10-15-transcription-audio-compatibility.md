---
title: Transcription audio compatibility
date: 2026-10-15
status: implemented
scope: swift-app-transcription
---

## Problem

An imported recording can open in AVAudioFile but fail when Apple reads its audio packets. The task displayed a raw AVFAudio error without a recovery action. An extension alone cannot establish decoder compatibility.

## Implemented solution

AppleTranscriptionAudio validates native inputs with Apple’s decoder and Ogg Opus with the bundled libopusfile decoder, reading the complete audio in bounded buffers. When decoding fails, it detects an existing FFmpeg executable in standard installation directories or absolute PATH entries. It first tries an M4A stream copy. If the repaired container still cannot be decoded, it encodes Ogg Opus at 48 kHz and 64 kbps. The audio filter preserves mono and stereo layouts and downmixes larger layouts to the supported mono/stereo set. Each result must pass a complete decode before acceptance. Staging files have owner-only permissions; failure and cancellation remove them. Cancellation also stops the converter process.

AppleRecordedTranscription now reads Opus incrementally with the same bundled decoder as playback. SpeechAnalyzer pulls PCM buffers through an AsyncThrowingStream; a continuous AVAudioConverter adapts them to the speech module’s selected format. Normal converter priming and end-of-stream draining preserve audio near the end. Each output buffer contains at most 4,096 frames. No PCM file or unbounded producer queue is created. Native files retain SpeechAnalyzer’s AVAudioFile path.

MeetingStore prepares replacements before admitting local transcription. A canonical library transaction journals the original audio, destination, and metadata. It writes updated audio references before removing superseded library audio; crash recovery restores the transaction with bounded-memory copies and atomic renames. Only regular files owned by the meeting library can be replaced; symlinks are rejected and external imports are left untouched. Filenames retain track identity; same-extension replacements and destination collisions get a distinct basename so playback cannot reuse a cached source URL. Failed or cancelled preparation removes staging files. Successful retries reuse the saved compact recording.

For a resumed request whose input changes, the superseded analysis request is retained for provenance and the request is admitted again using the saved replacement’s revisions. Existing transcript baselines and manual edits are preserved. Replacing audio also updates recording-profile filenames.
Task errors explain that encoding or container data may be unsupported or damaged, retain the underlying error code, and suggest installing FFmpeg and resuming or importing PCM WAV/AIFF. No installation or remote upload is performed.

## Reasoning

Apple’s native file decoder, supported containers, and speech-module PCM requirements are distinct. Stream copying avoids another lossy encode when container repair suffices. Opus uses the same compact format and bundled decoding path as other meeting recordings; saving PCM for every transcription would consume disk space and repeat work. Full preflight adds a decoding pass but catches failures before recognition starts. FFmpeg is instructed to stop on errors; a valid output cannot prove that a source with missing duration metadata was originally complete.
The supplied Tasks screenshot shows the error beneath Failed and again in attempt history. The intended design retains that layout and Resume action, replacing the error with a concrete reason and recovery action. Status text reports checking or conversion before transcription.

## Technical debt

None added. FFmpeg is an optional external dependency, not bundled or automatically installed. Its supported input codecs depend on the installed build; complete decoding with the selected native or Opus reader remains the acceptance criterion.

## Validation

The focused helper and storage run passed 13 tests in two suites. Audio tests covered native PCM without FFmpeg, actionable unreadable-input errors, cancellation, AAC stream copy, mono Opus conversion, repeat Opus input without FFmpeg, bounded buffers with continuous timestamps, exact final frame count, and a synthetic impulse immediately before EOF. The pulse test verifies timing and amplitude, not only duration. Invalid synthetic media is rejected by FFmpeg without changing the original.

Storage tests covered one-time replacement, preserved edits and prior admission, failed and cancelled publication, crash rollback with permissions, destination collisions, and symlink rejection. The final expanded storage/helper run passed 42 tests in six suites, including source changes after metadata validation, merging unrelated disk edits, multiple-file crash rollback, same-extension recovery, and source-name suffix recognition. Independent review moved audio backup creation immediately before mutation so a detected external edit cannot be overwritten by rollback, and removed duplicate created/modified audit events. The final combined run passed 11 tests in four suites, including actual Apple SpeechAnalyzer recognition of generated AIFF and Opus speech, sidebar interactions, and storage recovery. An independent conversion of the failing recording produced about 21 MB of mono Opus and passed complete decoding.

Both the combined working-tree build and the exact staged `make build-macos` release build passed, including bundle validation and signing. The staged source and test snapshot matched all 494 indexed files; strict Swift formatting passed for all 29 staged Swift files. Scoped Swift formatting and `git diff --check` passed. The build reported missing Command Line Tools linker search paths (`Developer/usr/lib` and `Developer/Library/Frameworks`). These are toolchain paths rather than deprecated APIs; no suppression was added. Follow-up: recheck after the next Command Line Tools update.

UI automation failed with “Sky Computer Use native pipe startup failed.” The supplied before screenshot was reviewed, but the resulting error text wrapping and Resume interaction have not been visually verified. No layout or control changes were made. The running app has not been replaced. The user requested a commit after validation. The commit includes the required audio-request provenance, transcript timing, and scoped canonical-save prerequisites; unrelated notes, recording-finalization, diarization projection, and UI changes remain outside it. Isolated staged validation caught a missing timing-slice dependency and a provider validation-order regression. The commit includes the slice helper and checks provider language support before audio request admission; the expanded suite passed all 96 tests in 15 suites, including actual Apple recognition, remote-provider behavior, canonical persistence, recovery, timing, and sidebar navigation. No push was requested, so CI was not triggered.

## References

- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [File analysis](https://developer.apple.com/documentation/speech/speechanalyzer/analyzesequence(from:))
- [FFmpeg audio format negotiation](https://ffmpeg.org/ffmpeg-filters.html#aformat)
- [AVAudioConverter normal priming](https://developer.apple.com/documentation/avfaudio/avaudioconverterprimemethod/normal)
- [AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile)
- [Speech module PCM selection](https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat(compatiblewith:))

The current SDK also exposes AssetInputSequenceProvider on macOS 27. The existing file API remains supported on the app's macOS 26 minimum; no deprecated API was introduced.
