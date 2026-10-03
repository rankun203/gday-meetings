---
title: Hide transcripts for muted playback tracks
date: 2026-10-04
status: implemented
scope: swift-playback-transcript
---

# Hide transcripts for muted playback tracks

## Problem and design

Muting a playback track changed the audio mix but left its transcript passages visible. A fresh isolated release Preview confirmed this with the microphone muted and its passage still shown. The synthetic baseline capture is local only at `/tmp/gday-mute-evidence/before-microphone-muted.png`.

Keep the existing player controls, transcript layout, timestamps, and speaker colors. Both individual mute controls and the track menu should filter the transcript for the player’s selected meeting, including while paused. Unmuting restores the original rows. Browsing another meeting must show that meeting’s complete transcript. When filtering hides every row, show **Transcript Hidden** with **Unmute an audio track to show its transcript.**

## Implemented solution

- `TranscriptPlaybackVisibility` resolves explicit live-source metadata and saved speaker tracks to the actual playback files. Provider track indices resolve through library filenames, so missing audio does not shift their meaning.
- `MeetingTranscriptView` keeps its complete row cache for transcript actions and stable speaker colors, and passes a filtered cache to the native table. Refresh the filter on mix or selected playback source changes, independently of playback ticks. Saved transcripts, history, summaries, and exports remain unchanged.
- Retain passages with unknown source metadata. Do not infer a source from a person’s name or visible speaker label. Where several files share one source, hide its passages only when all candidate files are muted.

## Reasoning

Use the transport’s `mutedTracks` rather than its single selected-track value: individual controls can create a custom mix or mute every track. Filtering presentation preserves transcript data and uses the existing native table’s stable row identities and incremental updates. No theme or new playback control is needed.

## Validation

- Before capture: latest working-tree snapshot in `/private/tmp/gday-mute-validation`, including concurrent uncommitted voice-review work; isolated production release Preview with synthetic content and silent playback. No real library or recording was opened.
- Added regression coverage for microphone/system mixes, unmute, other/no playback meeting, named/provider tracks, missing files, ambiguous sources, imported audio, and unknown legacy rows.
- `make format-macos` and `make lint-macos`: passed. Focused Swift tests: 45 passed across transcript visibility, playback, native transcript, and matched speaker-palette suites. This includes a paused transport integration test using actual mute and track-menu operations.
- Isolated `make build-macos-preview` built and signed the production Release app and Preview successfully. Build/test logs are local at `/tmp/gday-mute-after-build.log` and `/tmp/gday-mute-tests.log`.
- Inspected before/after Preview captures and accessibility state in Dark and Light: microphone mute removes its passage; system mute removes both system passages; all muted shows the recovery message; unmute and **All Tracks** restore rows with the same colors and text. These operations also worked while playback was running. Browsing the other synthetic meeting preserved its true **No Transcript Yet** state, and returning retained the mix. Keyboard transcript selection/editing remained available.
- Local-only captures: `/tmp/gday-mute-evidence/after-microphone-muted.png`, `/tmp/gday-mute-evidence/after-system-muted-light.png`, and `/tmp/gday-mute-evidence/after-all-muted.png`. No screenshot binaries are committed.
- Limits: synthetic audio and silent playback do not validate hardware output. Source mapping and different-meeting populated transcripts are covered by tests; this UI fixture’s second meeting has no transcript. Older-system appearance, small-window layout, and provider re-transcription were not revalidated because this change adds no custom controls or provider operations.
- Existing toolchain warnings remain: linker search paths for Command Line Tools `Developer/Library/Frameworks` and `Developer/usr/lib` are missing. The baseline copied build cache also reported stale files outside its original root; rebuilding in the isolated path removed those stale-cache warnings. No deprecation warnings were observed. Follow up by validating with a complete supported Xcode toolchain; this fix does not suppress or add linker paths.
- CI matrix is checked after pushing; runner status is reported separately.

## Technical debt

Retained limitation: older provider transcripts may lack source metadata, especially rows without a detected speaker. Those passages remain visible rather than being assigned to a track by guesswork. Recovering their source requires authoritative provider history or re-transcription; a future ingestion change should preserve exact source-file provenance for every provider row. This fix adds no schema migration or duplicate transcript storage.
