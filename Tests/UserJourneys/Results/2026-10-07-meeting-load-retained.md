---
title: Retained meeting navigation capture
date: 2026-10-07
status: unusable-trace
scope: macos-user-journey-performance
journey_id: meeting-navigation
---

# Retained meeting navigation capture

The user repeated rapid meeting navigation and requested retention of the Instruments trace and screen recording. Instruments saved a file at `/private/tmp/gday-meeting-load-retained-20261007/meeting-load.trace`, approximately 1.5 GiB, but later refused to open it with “Fatal error reported in run 1.” A saved file and readable table index do not establish a usable capture. Preserve it until the user requests removal. The supplied video remains in its original Downloads location.

## Alignment

Trace metadata: 16:14:27.556–16:18:09.855 Melbourne time, duration 222.299 seconds. The collection-start notification was received at 16:14:28.801, before the user began this video.

Video metadata: start 16:17:31 Melbourne time, duration 23.270 seconds. The recorded test is fully within the trace:

`trace seconds ≈ video seconds + 183.444`

Select trace interval **03:03.44–03:26.71** to inspect the video sequence. Metadata alignment has at least one-second uncertainty because the video creation timestamp has only whole-second precision; there is no shared frame/signpost marker.

## Capture and analysis limits

Instruments attached to the installed app with Time Profiler, Hangs, Core ML, GPU, and Neural Engine. It reported user-requested stop and saved the file. Its table index exported successfully. Parallel table exports consumed excessive temporary disk space; the CPU export failed and the other exports were stopped. This run therefore has no validated CPU/hang/accelerator summary yet. The saved trace has not been visually validated in Instruments.

The run issue database contains a type-2 issue for `Data stream: Time Mapping`, already present before table exports were attempted. This supports a capture/modeling failure; it does not prove that export-time disk exhaustion corrupted the trace. The underlying trigger remains unknown. The repository performance guide already documents prior finalization failure for long combined captures; that guidance should have been followed.

The combined capture was longer than the visible test and produced a roughly 13 GiB temporary kernel file before saving. Temporary kernel files from this capture and the earlier capture were removed after the saved trace and extracted first-run results were available. The retained trace and user videos were preserved. Further analysis should use one export at a time with sufficient free space; future captures should center a short window on the actual interaction. Do not repeat long combined captures or parallel decoding under the same disk conditions. With only about 21 GiB free at the follow-up check, remodeling was not attempted: previous decoding required substantial temporary space and exhausted the disk. Recovery is not established.

The [first run](2026-10-07-meeting-load.md) confirms substantial layout work and main-thread microhangs. Those measurements are not results for this second run.

## Viewing the trace

This trace currently cannot be viewed in Instruments. For a replacement capture, use a short Time Profiler/Hangs recording and verify a trial capture opens before asking the user to repeat the journey. Collect accelerators separately only when needed. Verify both CPU export and visual opening before calling a retained trace ready for inspection. The alignment above applies only if the existing trace becomes recoverable.

## Optimization candidates from source inspection

Current source recreates `MeetingDetailView` with `.id(id)` for every selection in `LibraryView`, and recreates the native transcript with `.id(meetingID)` in `MeetingTranscriptView`. Transcript setup uses nested `ViewThatFits` control layouts. Native transcript updates reload the table for source changes, then can reload again and force synchronous layout when width settles. Row-height caching belongs to the native coordinator, so recreating it loses that cache. These are concrete mechanisms to investigate, not individually proven root causes.

Prioritize retaining a stable detail/native container with explicit per-meeting state reset, reducing repeated adaptive sizing, and ensuring one necessary reload at a stable viewport width. Preserve editing focus, speaker assignments, playback subscriptions, scroll position, and accessibility. Source replacement legitimately changes rows; the aim is to avoid duplicate setup and layout work, not remove required refreshes.

Meeting reads already run in a detached task. Obsolete shared load operations can outlive selection and publish loaded meetings; investigate cancellation ownership and selected-detail observation before changing this behavior, since non-UI consumers may need the same operation. Avoid arbitrary selection delays or moving AppKit layout to background threads. Verify improvements with matched short navigation runs, trace stacks, input-to-content timing, and latest-selection correctness. No application code was changed for this diagnosis.
