---
title: Playback clock and resource audit
date: 2026-09-28
status: complete
scope: swift-app
---

# Problem

The user observed 4–30% CPU after generating and scrolling a summary with playback paused. Playback-driven UI also needed a single shared clock instead of transcript-specific seek notifications.

# Implemented solution

`PlaybackProgress` now publishes one coherent snapshot containing meeting identity, sampled position, scrub position, playing state, rate, and seek revision. A seek changes its position and revision together. Transcript and waveform views consume shared progress; playback controls do not notify the transcript directly. Meeting changes reset stale cursor state. Focused tests cover atomic seeks, repeated seeks, identity changes, and progress isolation from navigation/control invalidations.

# Resource audit

- A read-only eight-second sample of regular app PID 7144 at 12:19 on September 28 showed active audio refill/Opus decoding and waveform display-link work. The app had relaunched at 12:19:09. This sample includes playback and does **not** reproduce the earlier paused screenshot. The raw local sample is `/tmp/gday-resource-audit.sample.txt`; physical footprint was 65.5 MiB, peak 80.2 MiB.
- Streaming audio refills every 50 ms only while playing. Pause and end cancel the timer; close releases the engine, ring, readers, and buffers.
- Waveform display links are enabled only while playing, not scrubbing, with active scene and motion allowed. Static geometry is cached; display callbacks update only the reveal and cursor layers.
- Capture timers belong to a live capture session and are cancelled at stop. Recording elapsed-time views are conditional on recording.
- Library monitoring uses a recursive FSEvents stream, coalesces events, and excludes `index.db` and `.index*` writes. Notes use a directory dispatch source and a cancelled/coalesced 120 ms task. Neither is an idle directory polling loop. Import retries happen only for unsettled folders.
- Task recovery listens for launch/wake; remote polling exists only for unfinished transcription jobs. Summary streaming cancels its response task after completion and removes its draft. No completed-summary timer was found.
- The former Markdown view built independent block views and parsed inline text during view evaluation. The parallel Markdown change replaces it with one selectable native text document, updating only when the document/style changes. This is a plausible scrolling cost reduction, not evidence that it caused the reported idle CPU.

# Reasoning

A clock snapshot provides consistent state to all subscribers without introducing another timer. Actual position still comes from the audio callback path; display interpolation remains capped at 50 ms. Resource claims require a controlled paused measurement; a CPU screenshot or active-playback sample cannot identify a paused hotspot.

# Validation

Controlled isolated Preview PID 7883 was confirmed paused on Summary by the parent agent through accessibility state and a screenshot. Eight one-second CPU samples were 0.0, 0.0, 0.0, 0.0, 0.0, 11.4, 0.0, and 0.1%; resident footprint fell from 82 to 64 MiB. The overlapping stack sample spent 6,583 of 6,928 main-thread samples waiting for events and showed no repeated waveform, audio refill, or file-monitor work. The parent agent confirmed that the transient spike overlapped opening a File menu; this short window is therefore not an uninterrupted idle measurement; it does not reproduce sustained 4–30% cycling. Artifacts: `/tmp/gday-paused-preview.top.txt` and `/tmp/gday-paused-preview.sample.txt`.

The focused test invocation was blocked before compilation by SwiftPM manifest sandbox nesting (`sandbox_apply: Operation not permitted`). The consolidated rerun with appropriate execution permissions passed all 392 tests in 79 suites (`/tmp/gday-ui-final-tests.log`). An attempted read-only Preview selection through computer use was rejected by automatic approval review without a reason; no user app was stopped or modified.

## Uninterrupted paused Summary after the changes

The parent agent verified isolated Preview PID 18329 paused at 0:24 on Summary and left the UI untouched for measurement. Thirteen readings spanning twelve seconds were 0.0% CPU except one at 0.1%. CPU time rose from 7.29 to 7.30 seconds; memory remained 103 MiB. A simultaneous ten-second sample recorded 102.6 MiB physical footprint and 8,691 of 8,735 main-thread samples waiting for events. No continuous render or playback callback loop appeared. Artifacts: `/tmp/gday-paused-summary-after.top.txt` and `/tmp/gday-paused-summary-after.sample.txt`.

This establishes low idle resource use for the revised Preview with a loaded long transcript and paused Summary. It does not establish the cause of the earlier regular-app screenshot, or measure active scrolling frame cadence.

## Restart-test ownership

The full suite exposed two launch-recovery timeouts. Focused reruns passed. Inspection found that both fixtures kept the original `MeetingStore` and its recursive monitor alive while constructing a second owner for the same folder. Under a delayed full run, the original monitor could interpret the recovered owner's active journal updates as external changes and mark them failed/manual. Both tests now scope and release the seed store before opening its replacement and assert that the old instance has deallocated. Existing recovery assertions remain; no production task behavior changed.

The later 399-test run exposed a separate summary-queue test deadline: unrelated main-actor tests consumed its five-second wall window, leaving one summary queued after two requests. The fixture now uses the shared bounded main-actor wait helper (five-second polling budget, fifteen-second hard wall bound). It still checks that at most one summary runs, that the automatic item is cancelled, and that exactly three requests complete. No queue implementation changed. All seven focused `ManagedTaskTests` passed; the affected test completed in 0.395 seconds (`/tmp/gday-managed-summary-tests.log`).

Final combined validation after the follow-up UI work passed all 418 tests in 83 suites (`/tmp/gday-ui-consolidated-tests.log`). Formatting and diff checks passed. Existing Command Line Tools linker search-path warnings remain; no new Swift deprecation warning appeared. During the later computer-use connection timeout, a three-second Preview sample showed all 2,556 main-thread samples waiting for events, rather than an app main-thread hang (`/tmp/gday-preview-ui-timeout.sample.txt`).

# Technical debt

The main-panel versus Tags-sheet transcript audit found the same native renderer in both paths. Repeated wheel events were unnecessarily invalidating all available transcript row backgrounds twice per event. Hover suppression now redraws only on state transitions and shares one pending quiet-interval check. This is a concrete reduction in scrolling work, not proof of the entire reported window-to-window difference. See the transcript layout lifecycle worklog for the regression and pending comparative profiling.

The earlier regular-app CPU spike remains unexplained because the controlled paused sample did not reproduce it. If it recurs, collect a stack sample while the affected regular app remains paused in that state. No compatibility bridge or extra timer was added.

## Final batch validation

Pre-commit review covered the complete staged Core, Services, native UI, tests, and documentation changes. The final combined suite passed all 425 tests in 85 suites, including repeated scroll suppression, associated-meeting paging, and malformed file identity regressions (`/tmp/gday-push-final-tests.log`). Formatting, lint, and diff checks passed. Existing Command Line Tools linker search-path warnings remain. This validation does not establish sustained 120 Hz scrolling or explain the earlier regular-app CPU spike.

The final signed release Preview build passed (`/tmp/gday-push-final-build.log`); the associated-meeting footer was inspected after launch. The regular installed app was not replaced.
