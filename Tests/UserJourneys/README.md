---
title: User journey performance tests
date: 2026-10-07
status: draft
scope: macos-user-journey-performance
---

# User journey performance tests

These are examples for agreeing on a template and test scope. They are not approved acceptance tests or completed measurements. Each journey combines repeatable actions with a normal-use observation pass, where the user works naturally and reports delays. An agent can later follow the agreed actions, recording deviations and evidence gaps.

## Activities to triage

| Activity | Proposed priority | Question | Profiling focus |
| --- | --- | --- | --- |
| [Record while working](recording-while-working.md) | First | Do transcript, index, and task updates interfere with editing? | CPU, hangs, UI updates, writes; model hardware when enabled |
| [Select and browse meetings](meeting-navigation.md) | First | Does the latest selection become readable promptly? | CPU, waits, reads, memory |
| [Read and edit transcripts during layout work](transcript-layout.md) | With layout optimization | Do cached heights, background measurement, and table updates preserve responsive editing and stable scrolling? | CPU, hangs, allocations, cache and pending-work counters |
| [Find Voices](find-voices.md) | First | Is analysis efficient and compatible with responsive navigation? | CPU, storage, Core ML, GPU, ANE |
| Search while indexes change | Next | Does typing stay responsive and do results become current? | CPU, publication, index activity |
| Play audio while editing or navigating | Next | Does playback remain continuous and follow the intended recording? | CPU, decode, audio continuity |
| Stop, save, and reopen a long recording | Next | How long does finalization take, and are edits retained? | CPU, storage, task lifecycle |
| Generate a summary while recording | Later | Does streaming output cause repeated layout or writes? | CPU, UI updates, provider timing |
| Open a large library and browse People or voice review | Later | Are startup, paging, and review costs bounded? | CPU, memory, storage |

Begin with the usual configuration and one simpler control. Expand settings and sizes when a comparison answers a specific question, rather than running every combination initially.

## Proposed template

Every journey contains intent and questions, setup and variants, natural language actions, measurements and profiling, expected experience, and open decisions. Operator steps describe visible actions. Suspected implementation causes belong in analysis, separate from confirmed trace findings. Run results should be separate from the reusable journey.

## Shared run procedure

1. Record release build/source revision and local changes, Mac/chip and memory, macOS/Xcode/Instruments versions, power/thermal state, display refresh rate, window size, library size, audio source/format, providers/models, and settings. Avoid competing builds. Preserve active recordings and unsaved work; do not restart or replace the app during a real meeting.
2. Default to a separate synthetic library for mutations and matched comparisons. Fixtures are not yet prepared. A private normal-use pass can complement it. Agree on the library and audio source before execution; do not edit existing user content just to reproduce a test. Keep real content, names, identifiers, and paths out of tracked documents.
3. Capture idle and unprofiled baselines. Separate first-use/model startup from warm operation. Restarting the app does not establish a cold filesystem cache. Repeat short matched comparisons three times; report median, range, and sample count. Label single long-run observations as such.
4. Use targeted 30–60-second Instruments captures. Begin with Time Profiler and Hangs. Add SwiftUI for publication/layout, Thread State Trace for blocking waits, File Activity for storage, or Allocations for growth in separate passes as needed. Inspect native AppKit work too. Avoid continuous accessibility polling/full UI snapshots during quiet captures; document automation and profiler overhead.
5. For local inference, add Core ML and supported GPU/Neural Engine tracks in a matched pass. ANE means Apple Neural Engine. Inventory tools on the test Mac and report unavailable tracks. Configured compute units do not prove actual hardware use. Account for helper/provider processes and remote/network time separately. Do not change compute policy merely to obtain a hardware trace.
6. Timestamp input and visible completion with existing signposts or an external action log/screen recording. Distinguish command duration, visible latency, and sampled CPU time. Report latency distributions only with sufficient reliable events; otherwise show individual measurements and limitations. Missing instrumentation is an evidence gap, not zero work.
7. Keep raw traces, screenshots, and recordings private outside tracked files. Propose the earlier evaluation's 5 GiB trace budget and 20 GiB minimum free space. Stop profiling at the limit without stopping the user's recording. Save sanitized findings, capture intervals, confirmed causes, hypotheses, and untested cases. Delete raw Instruments traces after extracting useful data points unless the user requests retention. Preserve user-provided recordings. Restore test settings and remove only disposable artifacts created for the run.

## Proposed investigation triggers

Investigate repeatable interaction delays of 100 ms or more, lost input, stale content replacing the latest selection, audio gaps, or expanding processing backlogs. These are draft triggers, not a universal pass/fail contract. Agree on loading and throughput targets after baseline measurement. High background CPU can be acceptable when input remains responsive; low CPU can still accompany a blocked main thread. Frequent task banners alone do not establish a cause.

## Open decisions

- Accept this template, or prefer a shorter narrative or more tightly timed script?
- Which journey and exact everyday settings should we refine first?
- Which fixture sizes and durations represent normal and difficult use?
- Which latency, throughput, and pause targets should become acceptance criteria?
- Where should sanitized run reports live, and how long should private traces remain?

## References

The [earlier evaluation](../../docs/worklogs/2026-10-02-performance-evaluation-plan.md) and [recording work](../../docs/worklogs/2026-10-02-live-recording-performance.md) provide component evidence and prior capture limits, not proof that these journeys pass.

Apple's [hang analysis tutorial](https://developer.apple.com/tutorials/instruments/getting-started-with-hang-analysis) explains CPU and blocking investigation. [SwiftUI profiling guidance](https://developer.apple.com/videos/play/wwdc2025/306/) covers view update analysis. [Core ML profiling guidance](https://developer.apple.com/videos/play/wwdc2022/10027/) explains correlating model events with GPU and Neural Engine activity.
