---
title: Record while editing and navigating
date: 2026-10-07
status: draft
scope: macos-user-journey-performance
journey_id: recording-while-working
---

# Record while editing and navigating

## Intent and questions

I want to record while assigning speakers, correcting transcript text, and adding notes. Do transcript arrivals trigger indexing and task publication frequently enough to delay input? Can continuous embedding make useful progress without an increasing backlog? Treat those mechanisms as hypotheses until a trace connects them to a delay.

## Setup and variants

Follow the [shared procedure](README.md#shared-run-procedure). Prepare synthetic alternating-speaker speech with pauses, a generic person in the People Library, and editable saved meetings. Keep speech and cadence matched; source playback CPU is separate from app CPU.

| Variant | Settings | Purpose |
| --- | --- | --- |
| A | Capture only | Recording and interaction baseline |
| B | Live transcription | Transcript and resulting index activity |
| C | Transcription and Speaker Labeling | Added speaker analysis |
| D | Transcription, Speaker Labeling, and Speaker Association | Fuller workflow |

Start with the usual configuration and A. Add B/C when needed to explain a difference. Record exact providers, source, format, and settings. Do not assume an indexing disable switch exists. Proposed duration: 10 minutes initially, then a separate 60-minute growth run after agreement. Record actual transcript size and update rate.

## Natural language actions

1. Start a synthetic recording. Note time to recording and first transcript, when enabled. Observe one quiet minute with speech continuing.
2. Open Notes and type three generic sentences at normal speed. Correct a word and add a paragraph. Watch whether characters appear promptly and transcript updates interrupt focus.
3. Return to the transcript, scroll into history, and correct a completed sentence using the supported editing interaction. Commit while speech continues. Observe selection, scroll position, and edit retention after new output.
4. Associate an available speaker label with the generic person, then reopen the control to check it. Skip and report this step in variants without labels.
5. Switch between Notes, transcript, and Tasks five times at normal pace. Watch delayed clicks and task banners around transcript arrivals. Keep speech running.
6. Open a saved synthetic meeting and return to the recording. Check that capture continued and edits remain. Report navigation restrictions rather than forcing unsupported actions.
7. Repeat editing and navigation near the end. In the longer variant, sample near 5, 30, and 60 minutes. Between captures, let the user work normally and timestamp slowdowns.
8. Stop and save the disposable recording, reopen it, and check audio, assignments, transcript edits, and notes. During a real meeting observation, wait for the user to finish; stopping recording is not profiling cleanup.

## Measurements and profiling

Use Time Profiler/Hangs around input; SwiftUI for transcript/task publication and layout; File Activity for save/index writes. Add Core ML/GPU/ANE for local inference. Compare quiet and interactive intervals at matched speech cadence.

Record input-to-visible-response latency, longest stall, main-thread busy/wait stacks, process CPU, memory growth, transcript delivery rate, index starts/completions, writes, overlapping work, backlog, and audio gaps where observable. Correlate transcript arrivals, indexing, task UI changes, and delays on one timeline. Banner flashes are not reliable index counts. Mark missing timing/counter data explicitly.

## Expected experience

Typing and navigation respond promptly, new output preserves focus and edits, and recording remains continuous. Background work progresses without an expanding backlog or expensive full-history work on each update. Apply the shared investigation triggers; final targets remain open. Confirm saved correctness as well as responsiveness.

## Open decisions

Choose usual settings/providers/source, acceptable transcript delay, longer-run duration, and representative text size. Measure the resource tradeoff before choosing an opportunistic indexing policy; continuous embedding is desirable when it does not disrupt use.
