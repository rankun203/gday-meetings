---
title: Live transcription with This Mac
date: 2026-09-26
status: in-progress
scope: swift-app-live-transcription
---

## Problem

The recording view had no live text. The accepted design calls for local recognition through This Mac, durable drafts, separate sources, and recording that continues through recognition failures.

## Implemented solution

- macOS 26 SpeechAnalyzer/SpeechTranscriber adapter, two source sessions, runtime locale/model checks, automatic model installation, explicit per-language downloads and progress in the built-in This Mac provider panel.
- TimedAudioWriter emits aligned, trimmed captured PCM into bounded owned queues. Padding is not recognized. Conversion and inference run away from capture. Source/session identity prevents provisional updates from replacing the other source’s text.
- Separate observable live state and recording switch. No partial text is published through MeetingStore. Defaults enables Show Live Transcript; older macOS versions state the requirement.
- Private atomic live-draft checkpoints retain finalized phrases, source, locale, timing runs, and gaps. Five-second finalization deadline. Batch/live replacements preserve editable text and speaker identities; saved revisions can be restored. Failed revision persistence prevents replacement.
- Moved the research into `docs/design/` and updated references.

## Reasoning

Use the writer’s aligned PCM so speech and playback share a timeline through device changes. Keep an immutable draft separate from user-editable/batch text, then require an explicit selection for summaries and search. Use one local implementation rather than add an unmeasured remote fallback.

## Validation

Focused tests passed for draft replacement, source identity, owned queue copies/overflow, aligned writer trimming, private checkpoint round trips, and revision speaker identity. Integrated notes/library tests also passed (18 tests total in the first combined run). No deprecation diagnostics; known Command Line Tools missing linker search-path warnings remain.

Actual dual-source SpeechAnalyzer tests passed with generated Australian English and Mandarin. Both sources returned final phrases with valid timing; final words were retained. The test exposed resampler output overlapping timestamps, fixed by a continuous converted-frame cursor reset at source gaps. Models were already installed, so first-run downloads were not exercised. Combined live/notes/editor/library regression tests passed all 24 cases.

An authorized 90-second excerpt from a real local meeting passed dual-source recognition at wall-clock pace: 17 finalized phrases within the 60–150 second source range. The original files were read only, without speaker playback or cloud upload. Over 29 resource samples, the test process averaged 2.63% CPU (1.9–2.8%) and Apple’s recognition service averaged 2.12% (1.4–5.0%). Resident memory was 27.6 MiB and 122.6–132.2 MiB respectively. These are isolated decoding/recognition measurements, not combined capture/UI CPU or a full-meeting endurance result.

Final formatting and lint checks passed. All 241 integrated tests in 48 suites passed, including delayed final-result persistence during Stop. Packaged Preview checks are coordinated by the parent agent. No microphone capture was initiated by this sub-agent.

Final review also guards rapid toggle/Stop: Stop waits for already-running bounded finalization tasks before rejecting their last phrases. Failed finalization marks the draft incomplete. Model reservations are read from Apple’s persistent app reservation list and cannot evict active sessions.

## Technical debt

- Representative English/Mandarin/mixed speech quality, long-duration resources, route changes, and oldest-supported-OS launch are unmeasured. Runtime locale support is displayed; it does not certify the proposed accuracy gates. Complete the corpus and hardware matrix before claiming qualified language modes.
- Model reservations are bounded and app-requested; model sizes are not shown because system-managed storage sizes are unmeasured.
- Word timing is retained, but word highlighting and output-script conversion remain absent. Add conversion offset mappings and playback highlighting after accuracy/timeline validation.
- Live checkpoints rewrite the finalized draft atomically per stable result; benchmark two-hour meetings before deciding whether an append journal is needed.
