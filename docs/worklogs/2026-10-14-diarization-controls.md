---
title: Transcript and diarization controls
date: 2026-10-14
status: complete
scope: swift-app-ui
---

## Problem

Saved transcripts placed transcript history after the diarization controls. Starting diarization was separate from reviewing its results.

## Implemented solution

`MeetingTranscriptView` places Transcripts before Re-transcribe and Diarizations at the trailing edge. Compact layouts keep the same reading order. The renamed Diarizations panel contains the existing Diarize or cancellation action beside its heading, with label restoration and history below.

## Reasoning

The existing action is passed directly into `SpeakerLabelingHistoryView`, preserving provider readiness, transcript adoption, cancellation, and restoration checks. Native buttons and the existing popover retain their standard interaction.

Before editing, captured and inspected the saved synthetic conversation and its open history panel in `tmp/Gday Meetings Test Updated.app` (`com.gdaymeetings.macos.preview.corner20261014`). The existing toolbar showed Re-transcribe, Diarize, Diarization History, then Transcripts. The intended layout groups transcript selection with re-transcription and places diarization actions with their history.

## Technical debt

None.

## Notes

- Parent review confirmed the existing start/cancel action and its readiness, writable-library, and checkpoint-adoption checks are reused unchanged. Scoped formatting, lint, and `git diff --check` passed.
- Isolated `make build-macos` passed, including signing and platform verification (macOS 26.0 minimum, SDK 27.0). Log: `/private/tmp/gday-diarizations-release.log`. Existing Command Line Tools linker search-path warnings remain; no deprecation warnings were reported.
- Rebuilt release Preview: `tmp/Gday Meetings Controls Test.app`, bundle `com.gdaymeetings.macos.preview.diarizations20261014`. Captured the saved transcript and confirmed Transcripts precedes Re-transcribe, with Diarizations at the trailing edge. Transcripts opens its existing source menu; Escape dismisses it. The renamed popover opens with Diarize, Restore Labels, and saved history. Accessibility exposes the renamed control and panel action.
- The synthetic provider lacked its prepared model, so Diarize remained disabled; no inference or provider request was started. Running-task cancellation was reviewed in code rather than executed. Compact fallback order was reviewed in source; manual resize validation was interrupted by repeated automation window-reference failures. The popover screenshot was cropped to the parent window; its action and history were also verified through accessibility.
- No new tests were added for this presentation-only relocation. The earlier 196-test regression run covers the unchanged backend; the new release build typechecks the moved action.
