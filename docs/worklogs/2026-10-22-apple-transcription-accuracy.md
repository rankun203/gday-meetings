---
title: Apple live transcription accuracy preference
date: 2026-10-22
status: complete
scope: swift-app-transcription
---

## Problem

This Mac always requested fast live results and offered no accuracy preference.

## User Intention

Expose a provider setting to favor accuracy with slower results. The user accepted “Favor Accuracy” and “May improve transcription accuracy, but results can take longer.” The initial non-English claim was dropped because Apple documents a general tradeoff only.

## Implemented solution

Added a persisted Favor Accuracy switch under a Live Transcription section in This Mac settings. Existing and new settings default to off, preserving current live behavior. Saved-audio transcription continues to omit fast results.

Following screenshot feedback, combined the two description rows into one sentence: “May improve accuracy with slower results, starting with the next live transcription session.” The section heading supplies scope; the saved-audio explanation was removed from the control.

The controller snapshots the current preference before asynchronous startup. Both audio sources use the same snapshot. Turning the switch changes the next session, including a language restart, without interrupting active recognition. Tentative results and audio timestamps remain enabled.

## Reasoning

Inspected the running provider settings screenshot before editing. The page groups capabilities, readiness, and model downloads. A separate Live Transcription section places the preference and scope together before readiness. Apple’s fastResults option favors responsiveness over accuracy; removing it implements the accepted wording without promising a measured language-specific gain.

Reference: [Apple reporting options](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption).

## Technical debt

None.

## Notes

- Release build and code-sign verification passed with `make build-macos` in an isolated source copy under ignored `tmp/accuracy-validation`, based on `b46a0f8` plus the working tree. The running app was not replaced.
- All 103 focused tests in 16 suites passed, including settings migration/round trips, live reporting/timing options, live transcript lifecycle, restoration, and recorded transcription tests. Formatting and diff whitespace checks passed.
- Inspected the release preview screenshot against the proposed layout. The native switch exposes its label and on/off state to accessibility. Turning it on and closing/reopening settings retained the value. Preview uses synthetic data in a separate temporary library. Full-process persistence is covered by serialized settings tests; Preview creates a new library each launch.
- The wording follow-up passed a fresh release build, formatting, and diff checks. Its updated preview screenshot confirms one description row with no extra separator or saved-audio explanation. Existing behavioral tests were not repeated for this text-only edit.
- Generated English/Mandarin recognition passed with Favor Accuracy both off and on: both audio sources returned finalized text with valid timestamps, no reported failures, and successful finalization. These short synthetic samples do not quantify accuracy or latency improvements for real meetings.
- Build warnings: existing Command Line Tools linker search paths for `Developer/Library/Frameworks` and `Developer/usr/lib` are absent. Initial copied-cache stale-path warnings were also emitted. No new deprecation warning was observed. The user subsequently requested a local commit; pushing and CI remain outside this handoff.
