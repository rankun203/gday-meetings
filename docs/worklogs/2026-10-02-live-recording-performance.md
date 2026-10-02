---
title: Long recording performance and audio continuity
date: 2026-10-02
status: implemented
scope: swift-live-recording
---

# Problem

CPU use grew during a long recording, followed by fragmented live transcription. A read-only process sample found repeated historical transcript attribution dominating main-thread work. Speaker attribution scanned all activity intervals for each phrase, and frequent draft changes rebuilt historical rows. Full draft checkpoints also encoded synchronously on the main thread.

Diagnostic metadata confirmed an abrupt system-audio gap followed by sustained recognition-input drops. Framework logs showed repeated recognition interruptions. The initial trigger was not established; device switching, capture interruptions, and downstream stalls must be handled without assuming that any one caused this observation. No private meeting content or recording identifiers are retained here.

# Implemented solution

Implementation, release validation, and native preview checks are complete. Capture continues to own device recovery; consumers retain their source timelines across microphone and output changes. Real sustained recording and hardware validation remain open below.

## Progress

| Area | Status | Evidence and remaining work |
| --- | --- | --- |
| Historical speaker attribution | Implemented; regressions and benchmarks passed | Interval and gap range indexes plus per-phrase caches reuse unchanged attribution, including long overlapping ranges and gap storms. |
| Incremental transcript presentation | Implemented; regressions and benchmarks passed | Ordinary partial updates reuse finalized resolved and speaker-display buffers, rebuild only affected tail paragraphs, and preserve preceding native cells. Historical corrections and manual overrides retain broader invalidation paths. |
| Recognition input backlog | Implemented; synthetic regressions passed | Pull-based input uses the existing two-second PCM queue, removing the eight-packet intermediate buffer. Stalled-delivery and format-change tests passed. Real recording replay remains unvalidated. |
| Gap reporting | Implemented for transcription and labeling; regressions passed | Both use bounded asynchronous reporting and final drains; input does not wait on gap UI callbacks. |
| Draft persistence | Implemented; regressions passed | One background save and one latest pending snapshot; finalization drains saves. Error/recovery assertions now await persistence and retain their checks. |
| Device-change continuity | Existing architecture reviewed; synthetic regressions passed | File writer, clock, and subscriptions survive source-format changes. The test checks exact delivered packet endpoints and allows the streaming resampler's retained tail. Actual MacBook/AirPods switching has not been tested. |
| Sustained CPU and recognition quality | Open | No before/after application CPU or long-running recognition-quality result yet. The initial interruption's cause remains unproven. |
| Settings tab stability | Implemented; native preview passed | Removed runtime insertion of toolbar spacers. General, Service Providers, and Data retain the same tab positions when switching. |

The first isolated suite found two assertions needing adjustment: the source-format test's resampler-tail tolerance and an existing test expecting checkpoint errors synchronously. Both pass in the final suite; no assertions were removed.

# Reasoning

The existing capture manager already replaces source engines or taps while keeping the recording epoch, file writers, and live fan-out stable. A short hardware interruption should produce an explicit gap followed by continued processing. Subscriber metadata and UI work must not block the audio feed. More queue capacity alone would delay failure without removing work that grows with meeting length.

No visual redesign is intended. Existing live transcript screenshots establish the layout to preserve, including timestamps, speaker badges, manual edits, and provisional text. Synthetic histories and source changes will validate output equivalence, timeline continuity, bounded queues, and scaling without changing the active recording.

# Technical debt

- Incremental presentation still compares array prefixes and maintains indexes. Manual overrides retain full resolution; a historical correction rebuilds its affected display suffix. This preserves correction semantics without introducing a second authoritative transcript, but some validation work remains linear in history length. Profile real long recordings after this change; introduce explicit revision/range invalidation only if those remaining checks are material.
- Under sustained consumer starvation, capped loss metadata summarizes several disjoint losses as an explicitly uncertain interval. This keeps memory bounded but can conservatively mark successfully processed audio inside that span. Retain the uncertainty distinction; exact loss histories would need a separately bounded or persisted event stream.
- Final durable completion waits for the background checkpoint writer. A hung filesystem can delay completion even though encoding no longer blocks the UI. A future cancellation/storage-recovery design must preserve the last accepted draft rather than silently timing out its save.

# Validation

The final integrated snapshot passed 661 tests in 115 suites in 169.985 seconds, including opt-in benchmarks. Formatting, strict lint, and `git diff --check` passed. Source and test snapshots match the isolated checkout. The isolated release build passed in 139.14 seconds through `make build-macos-preview`, which runs `make build-macos`; plist and signing checks passed. The user's installed recording remains untouched.

Native preview comparison preserved transcript layout, timestamps, badges, and provisional styling. Turning Transcribe off removed only the provisional tail; turning it on restored the fixture state. General's association dropdown includes the Nemotron fixture, accepts its selection, and retains it after tab navigation. General, Service Providers, and Data keep stable tab positions. Provider health in this preview is synthetic; model verification and lifecycle behavior are covered by the automated tests.

Existing Command Line Tools linker warnings report missing Developer library/framework search directories. No deprecated API or new concurrency warnings remain. No push was requested; the remote macOS CI matrix was not run.

Synthetic debug-build benchmarks compare the previous full-history algorithms with the new paths on the same generated inputs. All measured outputs match the reference. These are component timings, not total app CPU, release timings, or recognition-quality measurements.

| History | Speaker attribution, three evolving partial/activity updates, before → after | Display assembly, ten partial updates, before → after |
| --- | --- | --- |
| 5 minutes | 70.97 → 2.30 ms | 9.11 → 1.60 ms |
| 45 minutes | 4,489.88 → 18.75 ms | 75.88 → 1.89 ms |
| 120 minutes | 31,146.55 → 48.10 ms | 201.88 → 3.51 ms |

The attribution tests assert no finalized phrase reassembly during those partial updates. Display tests assert at most three paragraphs rebuilt. Additional warm-cache tests cover 5,401 and 14,401 gaps, including a long overlapping interval; unchanged results are reused, so those timings are not representative of fresh attribution. Regressions also cover late gap/label changes, tied timestamps, manual edits, people changes, source-format changes, and bounded stalled-consumer behavior.

Remaining validation: real sustained CPU/recognition behavior and physical microphone/output switching. Synthetic continuity checks do not establish hardware behavior.
