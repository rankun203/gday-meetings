---
title: Audio task progress
date: 2026-10-15
status: complete
updated: 2026-10-16
scope: macos-audio-processing
---

# Audio task progress

## Problem

Recorded transcription and speaker diarization exposed status text without measured progress. Remote transcription discarded the distinction between waiting in a provider queue and processing audio.

## Implemented solution

- This Mac transcription reports finalized audio time from SpeechAnalyzer across the sum of sequential input-track durations, including silent input. A bounded stream serializes callbacks and drains before leaving the phase.
- Community-1 reports segmentation chunks, followed by voice analysis, speaker grouping, and voice-example preparation. Segmentation completion does not imply completion of embedding or clustering.
- Remote transcription reports audio preparation, completed upload files, submission, provider queue or processing status when supplied, and saving. Unknown provider work remains indeterminate.
- Successful local processing measurements use SuspendingClock to exclude system sleep and avoid wall-clock changes. Model preparation, separate conversion, queue waits, and saving are outside the measured intervals. Apple's streamed decoding remains part of its transcription measurement. Samples are committed only after the operation saves successfully and its job attempt remains current and uncancelled.
- Synthetic tests cover summed audio duration, ordered callback draining, provider status distinctions, stale attempts, and cancellation before performance-cache updates.

## Reasoning

Apple documents the volatile range start as the finalized analysis frontier; its end only indicates submitted input. FluidAudio's segmentation callback precedes completion of its overlapping embedding worker, so a full diarization percentage based on that callback would be incorrect. The displayed numeric fraction describes the named phase. Remote protocols do not provide trustworthy work totals or processing durations, so no remote time estimate is fabricated.

## Technical debt

None. Providers with unknown totals remain indeterminate by design. Community-1 exposes no embedding or clustering progress; estimates during those stages remain unavailable rather than treating segmentation as complete inference.

## Notes

Apple's current API reference and the installed macOS 26 SDK agree on the callback contract: [setVolatileRangeChangedHandler](https://developer.apple.com/documentation/speech/speechanalyzer/setvolatilerangechangedhandler(_:)) and [volatileRange](https://developer.apple.com/documentation/speech/speechanalyzer/volatilerange). The app already requires macOS 26. Validation is coordinated with the parent task in an isolated checkout; this subtask does not rebuild the running app.

Final release, test, review, and UI results are recorded in the [parent worklog](2026-10-15-task-progress.md).
