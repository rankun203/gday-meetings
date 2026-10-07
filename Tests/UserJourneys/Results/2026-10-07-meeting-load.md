---
title: Meeting navigation performance observation
date: 2026-10-07
status: measured-with-limitations
scope: macos-user-journey-performance
journey_id: meeting-navigation
---

# Meeting navigation performance observation

## Findings

This normal-use observation reproduced main-thread stalls during rapid meeting navigation. Instruments recorded 13 microhangs, lasting 260–383 ms. Twelve occur around video seconds 52–64. Samples favor investigating UI layout and rendering first; they do not establish which publication or layout constraint caused the work. No application code was changed.

The trace contains 10.309 seconds of sampled process CPU, including 9.790 seconds on the main thread, across 47.302 seconds of capture. Approximately 95% of sampled app CPU is on the main thread. Whole-capture averages hide the bursts: trace seconds 29–30 and 33–34 each contain about 0.98–0.99 seconds of main-thread samples per second, close to one full CPU core.

Main-thread inclusive stack weights include 6.159 seconds in AppKit `layoutSubtreeIfNeeded`, 5.546 seconds in `NSHostingView.layout`, and 2.123 seconds in `LayoutEngineBox.sizeThatFits`. Native transcript row-height measurement accounts for 0.554 seconds in `TranscriptHeightCache.measure`. These stacks overlap and must not be added. Generic event-loop frames in these samples are ancestors of active layout work, not evidence that the thread was idle or blocked waiting for events.

Core ML and ANE interval exports contain no rows. Of 317,360 GPU interval rows, 308,596 are attributed to WindowServer and six to the app. Other rows include browser and screen-recording activity. Intervals overlap, and their count is not GPU utilization; WindowServer activity cannot be assigned solely to this app. These exports provide no evidence of an inference bottleneck. Accelerator attribution is saved separately in the private extracted summary.

## Video alignment

Video metadata places its start at 16:02:22 Melbourne time (05:02:22 UTC), with duration 66.313 seconds. Trace metadata places capture at 16:02:49.896–16:03:37.198 Melbourne time. Thus:

`video seconds ≈ trace seconds + 27.896`

The video start has only whole-second metadata precision. Treat this as approximate wall-clock alignment with at least one-second uncertainty, not frame-accurate synchronization. There is no shared input/signpost marker to refine the offset. The trace overlaps video seconds approximately 27.90–66.31 and continues about 8.9 seconds beyond the video.

The initial 27.90 seconds have no profiling coverage. The operator announced readiness before confirming the trace's actual collection start. Future runs must verify collection with a shared visible marker before the user begins.

| Trace seconds | Approximate video seconds | Main-thread microhang |
| ---: | ---: | ---: |
| 0.531 | 28.427 | 383 ms |
| 24.366 | 52.262 | 291 ms |
| 25.713 | 53.609 | 288 ms |
| 28.935 | 56.831 | 296 ms |
| 31.338 | 59.234 | 286 ms |
| 32.723 | 60.619 | 279 ms |
| 33.002 | 60.898 | 260 ms |
| 33.578 | 61.474 | 291 ms |
| 34.793 | 62.689 | 279 ms |
| 35.372 | 63.268 | 305 ms |
| 35.680 | 63.576 | 291 ms |
| 35.971 | 63.867 | 293 ms |
| 36.263 | 64.159 | 298 ms |

Video sampling shows rapid selection changes and alternating loading/detail states in the later navigation interval. One-second overview frames do not measure exact click-to-content latency or prove stale results. No private meeting titles, people, or transcript passages are reproduced here.

## Setup and evidence limits

The user operated the installed app in their normal library and supplied a screen recording. The trace attached to the installed app with Time Profiler, Hangs, Core ML, GPU, and Neural Engine instruments. Hardware: MacBook Pro, M1 Max GPU, 64 GiB memory; macOS 26.6.2; Instruments 27.0 (27A266a). Exact installed source revision, library dimensions, cache conditions, keyboard repetition cadence, power/thermal state, and competing workload were not established. This is one exploratory run, not a controlled three-run benchmark.

The Hangs reporting threshold was greater than 250 ms; lack of a hang event does not establish sub-100-ms responsiveness. CPU values are statistical sample weights, not exact thread accounting or wall-clock task latency. File Activity, SwiftUI cause-and-effect, and waiting-thread sampling were not captured. The screen recorder and combined accelerator capture add overhead; its magnitude was not measured. The raw trace finalized at about 705 MiB after larger temporary recording data; cleanup follows the user's instruction to delete traces after extracting useful data.

Private extracted CPU/hang/GPU summaries remain in `/private/tmp/gday-meeting-load-20261007/`. Raw traces are deleted after extraction unless the user asks for retention. The user's video is preserved.

## Next investigation

Use a short CPU/SwiftUI capture with a shared start marker and matched navigation cadence to identify what invalidates layout. Inspect transcript row sizing and the hosting layout around selection transitions. Measure actual input-to-content latency and superseded loads separately; this run does not establish disk read, decoding, cancellation, or persistence as the cause. Compare a small and long synthetic transcript to determine whether cost scales with content while checking that the latest selection remains correct.
