---
title: Overlapping transcript playback
date: 2026-10-03
status: complete
scope: swift-app-ui
---

# Overlapping transcript playback

## Problem

Playback highlighted only the latest segment start across the transcript. A microphone passage lost its highlight when a system-audio passage began, even when both covered the current playback position. Display rows discarded segment end times, so the final highlight also persisted through silence.

## Design evidence

Inspected the supplied screenshot and captured the running app before editing. The transcript uses a blue row background and accent timestamp for one active passage, alongside independent source waveforms. Keep the existing layout, controls, and highlight styling. Apply that styling to every passage containing the playback time. Use the latest active start as a single scroll anchor, preserving manual-scroll and editing suppression. A segment includes its start and excludes its end; gaps show no active passage.

## Implemented solution

Saved transcript segments and live paragraph display rows now require end times. The native coordinator caches intervals sorted by start, with prefix maximum ends to stop scanning once preceding intervals have all expired. Its active row set drives existing and reused native cells and row backgrounds. Only changed highlights are updated on clock ticks; text measurements and transcript reloads remain outside the playback loop. Invalid, empty, and nonfinite intervals cannot become active. Source mute controls continue to affect audio output independently of transcript timing.

The synthetic conversation has microphone and system passages overlapping from eight through ten seconds. Its saved live checkpoint retains the conversation’s canonical segments instead of replacing them with an unrelated one-row fixture. Regression tests cover equal starts, nested and unsorted intervals, exact ends, gaps, reverse scrubbing, transcript replacement, another meeting, invalid timing, reused cells, and visible highlight expiration.

## Reasoning

Using complete intervals handles overlapping sources and speakers without assuming one active row per source or relying on speaker labels. Required end times avoid a compatibility fallback that could leave stale highlights indefinitely. The existing single scroll anchor avoids competing scroll animations when several passages are active.

## Technical debt

None added or retained by this change. The interval scan stops using prefix maximum ends; unusually long overlapping intervals can require inspecting a larger prefix. The existing selected-transcript storage and rendering architecture remains unchanged.

## Validation

The final isolated `make build-macos` passed, including packaging and signing, in 190.37 seconds. UI Preview packaging passed. The existing Command Line Tools linker warnings remain for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths; no deprecation warnings appeared. These toolchain paths are outside the change; the existing build-dependency worklog records the follow-up to repair the selected toolchain configuration. Swift formatting, lint, and diff whitespace checks passed.

All 27 focused native and live-transcript UI tests passed. The full run completed 731 tests in 129 suites with 11 polling and storage-recovery issues in ManagedTaskTests, SummaryStreamingTests, and LiveTranscriptEditingTests. A separate focused rerun of those three suites passed all 33 tests. The complete concurrent run is therefore not reported as passing. Initial new test-fixture errors were corrected by configuring the native table’s data source and column; the existing deep-position test now expects no highlight after all replacement intervals have ended.

Captured and inspected the changed Preview in System (dark) and Light appearance. A paused waveform seek to 00:08 highlighted both system and microphone rows with the existing fill and timestamp emphasis. Keyboard seeking to 00:13 left only the microphone row highlighted; 00:18 cleared both. Reverse seeking restored both highlights. Play and Pause advanced to a later gap without leaving stale highlights. Row positions and text metrics stayed stable. Synthetic screenshot evidence is saved outside the repository at `/tmp/gday-overlap-dark.png` and `/tmp/gday-overlap-light.png`.

The user’s running app and library were preserved. UI Preview uses synthetic content and silent playback; hardware output, recognition timing accuracy, narrow-window layout, and changed accessibility preferences were not retested. No new controls, geometry, animation, or audio behavior were introduced.
