---
title: Recording endurance and processing cost
date: 2026-10-02
status: measured
scope: swift-app-performance
---

# Notes and Summary capacity — October 3

![Aligned CPU, memory, disk, and operation-time comparisons over elapsed time and payload size, with separate GPU and Neural Engine probes.](assets/2026-10-02-recording-endurance/capacity-comparison.svg)

- **Notes does less work per edit.** At 100 KiB, main CPU fell from 36.9% to 22.2%; p95 edit-and-layout time fell from 31.9 to 20.3 ms. At 500 KiB, CPU fell from 99.9% to 56.1% and p95 from 101.8 to 54.3 ms. The 10 KiB case meets the 16.7 ms operation target; larger cases do not.
- **Summary's quadratic timestamp scan is fixed, but visible rendering still scales poorly.** At 100 KiB, p95 fell from 1,995 to 181 ms. The fixed run completed, delivering 5.74 updates/s rather than the requested ten. At 500 KiB it delivered only 1.26 updates/s. Hidden Summary at 100 KiB uses 3.3% main CPU, identifying visible document work as the remaining cost.
- **These UI workloads are CPU-bound.** Separate 20-second device probes show negligible app GPU activity and no recorded ANE or Core ML events. They do not measure model inference. System GPU includes other apps; its before/after difference is not a measured effect of these fixes.

| Final release workload | Initial KiB | Mean main CPU | p95 operation, ms | Achieved updates/s | Peak footprint, MiB | Process writes, KiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Notes append | 10 | 14.1% | 12.2 | 9.68 | 53.1 | 56 |
| Notes append | 100 | 22.2% | 20.3 | 9.72 | 86.4 | 180 |
| Notes append | 500 | 56.1% | 54.3 | 9.76 | 212.0 | 3,632 |
| Summary visible | 10 | 52.5% | 70.9 | 10.00 | 62.0 | 0 |
| Summary visible | 100 | 97.3% | 181.5 | 5.74 | 72.2 | 0 |
| Summary visible | 500 | 99.6% | 807.0 | 1.26 | 118.4 | 0 |
| Summary hidden | 100 | 3.3% | 1.4 | 10.00 | 61.5 | 0 |

Each unprofiled run uses a fresh release test process, 25 seconds of input and five seconds of settling, without concurrent compilation or tracing. Notes inserts one character at a time into synthetic Unicode paragraphs with four image references and flushes persistence. Summary adds one paragraph per update, ending with about 43, 119, and 504 KiB respectively. Its synthetic streaming path does not request a provider or persist a final generated summary; zero writes here does not describe a complete generation task. The operation timer includes a run-loop opportunity and forced layout; deferred work may follow. It is **not key-to-photon latency**. These single short runs establish tested cases, not a universal content limit or long-session stability.

“Before scan fixes” already includes Summary publication isolation and the image-reference cache. “After” adds dirty-range styling, linear reading timestamps, and the Notes gutter index. The before Summary runs at 100 and 500 KiB hit latency guards; triangles retain their observed values and actual shorter input windows, not completed capacity results. The 500 KiB before run had one 45.5-second operation, so its footprint is not a matched-duration memory comparison. Input-at-start, increasing image counts, and a final provider-driven/full-library repeat remain separate follow-ups.

## Repetitive work removed

**Problem and implemented solution:** Unchanged Notes layout compared and rescanned complete strings. Styling now consumes completed character-edit ranges, expands them to paragraphs, and skips unchanged transactions. Image references are parsed once per actual edit rather than again on unchanged layout. The timestamp gutter caches derived UTF-16 line offsets once per document revision and uses binary lookup for visible fragments. Summary reading resolves block timestamps in one linear pass instead of rescanning all preceding lines for every block. Draft publication remains confined to the Summary document.

**Evidence and reasoning:** After the image cache alone, a 21.30-second Notes probe still spent 2.430 inclusive CPU-seconds in layout preparation, including 1.852 in string equality. After styling, repeated line lookup accounted for 1.276 seconds in a 21.21-second probe. The final 21.00-second Notes probe uses 4.543 main CPU-seconds; the retained top frames instead include document replacement (1.131 seconds), image-reference parsing (0.873), and view-graph updates (1.031). Inclusive values overlap and cannot be added. This identifies the next candidates without assuming all remaining CPU is layout.

Summary's initial 21.17-second probe spent 11.678 of 17.931 main CPU-seconds in repeated timestamp lookup. An independent release parser comparison at 100 KiB took 6,314 ms for repeated scalar lookups versus 4.6 ms for the linear metadata pass; constructing the full fixed reading document took 73.5 ms. The visible workload still rebuilds Markdown and attributed content on each delivery. Increasing the streaming delay would mask that cost, so cadence remains unchanged.

**Design and validation:** Preserve the inspected Notes and Summary layouts, timestamps, images, selection, undo, and streaming semantics. Earlier Summary preview checks passed in light and dark appearances. The Notes component screenshot after image caching showed the expected editor and image structure. Final gutter/style changes passed 53 release tests, including Unicode, CRLF, grouped edits, empty/trailing lines, native undo/redo, timestamp equivalence, and image behavior; the preceding combined reader/style run passed 88 tests. Summary publication/streaming checks passed 21 tests. The final signed release build passed in 139.64 seconds. Existing missing Command Line Tools search-path warnings remain; no new application API deprecation was reported.

Final full-library visual/input validation remains blocked: Computer Use refused access to the newly packaged test app despite the user's explicit authorization. Automated native component runs completed, but no final screenshot or measured real keystroke-to-display result is claimed. One sandboxed launch aborted during macOS application registration before measurement; it was excluded and the authorized desktop-session retry completed.

**Reproducibility:** Use the [durable performance scripts](../../apps/client-macos-swift/scripts/performance/README.md) and [interaction runbook](../../apps/client-macos-swift/docs/PERFORMANCE_TESTING.md). The scripts build release fixtures, run bounded workloads, capture all devices, monitor an explicit PID every five minutes, validate/aggregate exports, and draw the shared SVG. Successful captures remove intermediate traces and exports; failures retain evidence within the shared disk guard. The monitor records deadlines but does not stop or save recordings. Native workload and capture runners were exercised; the reusable long-recording wrapper has counter-conversion checks but has not yet had a new multi-hour run.

The plotted [numeric data](assets/2026-10-02-recording-endurance/capacity-data.json) and [labels](assets/2026-10-02-recording-endurance/capacity-labels.json) regenerate the SVG using `plot.py`. SVG fonts are outlined and the rendered figure was inspected. Metric checks, Python lint/formatting, shell syntax, and diff checks passed. Workload manifests retain exact binary hashes: final Notes `c6d8ff75fa360b699cdd3075026f7b0bc4e60bace3791d8521be2ee3b201bee2`; Summary `aba8dd9b9a043fc2d0f631ed51200c91b5ce1d518c7b2a4cbf73248425a101dd`. These are source snapshots based on `847b840` plus the repairs, not claims about the installed app. Concurrent transcript migration and build-script commits were preserved.

**Technical debt:** No second content store or delayed-render compatibility layer was added. Derived caches have explicit mutation invalidation. Existing whole-document Markdown replacement, Notes normalization/reference parsing per edit, and full-window verification remain; profile and repair those paths next, then repeat provider-driven typing/navigation and long-session tests. The tools depend on Apple's test-host path and Instruments XML schemas; validate them after toolchain upgrades. Short device probes cannot establish accelerator use over the whole task. Release validation does not establish that large Notes editing is realtime.

# Earlier recording measurements

![CPU, physical memory, app GPU, system GPU, and Neural Engine activity across the recording phases. Blank intervals are unmeasured.](assets/2026-10-02-recording-endurance/resource-comparison.svg)

- **Ordinary app CPU was about 47% with speakers, 41% with transcription only, and 30% recording only.** These sequential runs have different source material and caches; they are not controlled feature-cost estimates.
- **Summary and Notes now have complete task CPU captures.** Summary reaches one core on the main thread, dominated by view-graph/layout work; Notes input averages 93.1% main CPU with substantial image/change handling. See the complete-task comparison below.
- **The blank transcript remains unresolved.** The user saw a brief blank transcript after returning from another app. Nearby CPU samples show no large spike, but no Instruments trace overlaps the event. Quiet main-thread CPU is lower with fewer live processing features; that does not establish frame or input latency.
- **Saving differed sharply between runs.** The first speaker-enabled save reached **1,494 MiB** of physical footprint. Transcription-only reached **382 MiB**, recording-only stayed near **345 MiB**, and the repeated speaker-enabled save reached about **1,015 MiB**. Only the recording-only trace captured finalization; the final repeat’s intended save trace ended before Stop was clicked.
- **Accelerator work changes with processing mode.** The initial speaker-enabled probe recorded Nemotron GPU work and 16.6% Neural Engine active wall time. Transcription-only probes recorded no app GPU work and 1.8–2.0% Neural Engine activity. All twelve recording-only probes recorded neither. Ten regular probes in the final repeat recorded 0.78–0.84% app GPU and 15.7–17.0% system Neural Engine active wall time. The last two regular probes were skipped while manual workloads held the capture lock.

CPU uses one core as 100%. Memory means physical footprint, not RSS. GPU and Neural Engine points show active wall time within short captures, not device-capacity utilization or energy. Their scopes differ and their percentages must not be added.

## Progress

| Part | Processing | Saved duration / measured interval | Status |
| --- | --- | --- | --- |
| 1 | Transcription, speaker labeling, and association | Audio 2:18:55.929; first 120 monitored minutes compared separately | Complete |
| 2 | Transcription only | Audio 1:02:37.678; first 60 monitored minutes compared separately | Complete |
| 3 | Recording only | Audio 1:04:31.214; first 60 monitored minutes compared separately | Complete; 12 combined device captures |
| 4 | Transcription, speaker labeling, and association again | Audio 1:01:24.524; first 60 monitored minutes compared separately | Complete; 10 regular combined captures, with two scheduled gaps |

All recordings use microphone and system audio, voice processing, Opus, and the same installed release. The user confirmed that journal growth was fixed separately; it is not an open finding here, and the app was deliberately not upgraded during this comparison.

## CPU cost of complete tasks

![One-second app and main-thread CPU across complete Summary, Notes typing, and navigation task windows, aligned to task start.](assets/2026-10-02-recording-endurance/task-cpu-comparison.svg)

**Summary generation saturates the local main thread through repeated view-graph updates and layout.** The longer recording reached **99.9% main-thread CPU** in a captured second without accessibility inspection. Hiding Summary and showing Notes did not remove the saturation: the late request window averaged **99.0% main-thread CPU with no Markdown-render samples**. This identifies UI update/layout work as the main measured cost; it does not identify one exact view or prove a specific source fix.

| Task window | Elapsed seconds | App CPU-seconds | Main CPU-seconds | Mean main CPU, % of one core |
| --- | ---: | ---: | ---: | ---: |
| Summary visible, shorter recording | 29.795 | 17.218 | 16.839 | 56.5% |
| Summary hidden, Notes visible | 22.961 | 20.768 | 20.462 | 89.1% |
| Summary visible, longer recording | 27.458 | 18.537 | 18.288 | 66.6% |
| Saved Notes: 12 paragraphs, about 2,200 characters | 21.564 | 20.713 | 20.071 | 93.1% |
| Six tab changes and two meeting changes, including pauses | 28.110 | 8.599 | 8.576 | 30.5% |

Summary windows come from persisted managed-task start/finish logs and fit completely inside 90- or 150-second CPU traces. Provider-request windows were checked separately; response completion is not the same as task completion. Notes and navigation windows use automation action timestamps, **not keystroke-to-paint or click-to-render latency**. CPU-seconds are sampled CPU weights, not elapsed time. No first-token timestamp was available.

For the longer Summary task, inclusive main-thread samples include **13.841 CPU-seconds of view-graph updates**, **6.361 of size fitting**, **3.192 of hosting minimum-size work**, and **1.298 of Markdown rendering**, with only **8 ms of accessibility work**. These categories overlap and must not be added. Markdown/regular-expression work is present but is much smaller than the broader view/layout cost. After task completion, main CPU returned near idle: 0.98% for the shorter visible run and 0.43% for the longer run over their measured settling windows.

The complete Notes input window includes **5.426 CPU-seconds in change handling**, **5.347 in image-presentation paths**, **3.331 in size fitting**, and only **11 ms of accessibility work**. This is substantial main-thread work during input, unlike the earlier partial typing capture. Navigation is more confounded: **3.646 of its 8.576 main CPU-seconds** include accessibility inspection. Tab actions alone used 5.286 main CPU-seconds over 8.719 seconds; meeting actions used 1.801 over 2.242 seconds. These are automated workload costs, not measured user-visible delays.

The longer recording has **1,860 timed rows / 39,995 transcript characters**, without Notes or images. The shorter one has **584 rows / 13,772 transcript characters**, plus **14,172 Notes characters and four images**. The longer Summary contained **3,669 characters**, versus **2,186** for the latest shorter result—about 68% more output. That shorter result is from the hidden run; the visible run’s output was replaced, so these output sizes are not a matched pair for the CPU comparison. Separately, the longer visible task used 7.7% more app CPU (18.537 versus 17.218 CPU-seconds). Inputs, generated output, and request duration differ; this is not a controlled scaling result.

These full-task traces measure **CPU only**. A long CPU+ANE+Core ML attempt failed during finalization; its timing samples survive but its stacks do not. Earlier short all-device probes remain separate evidence and cannot supply missing GPU/ANE measurements for these exact task windows. The installed build was unchanged. Current source includes the newer `dcc4679` canonical-transcript and `8fd4a75` saved-row changes, but these do not validate a repair for Summary publication/layout or Notes image work. Repeat the same tasks on the proposed fix using the [performance runbook](../../apps/client-macos-swift/docs/PERFORMANCE_TESTING.md).

The Summary repair and its controlled publication comparison are documented below. The installed baseline remains unchanged; synthetic results do not replace a full provider-driven comparison. Notes image-presentation stacks primarily contain repeated string comparisons and parsing, not image decoding.

### Payload and typing-latency evaluation

The next controlled matrix seeds 10 KB, 100 KB, and, if bounded screening succeeds, 500 KB documents before measurement. It holds incoming fragment size and update rate constant, records actual UTF-8 bytes and line counts, and includes an idle tail. Notes adds single-character typing, an edit near the beginning, and saving. A fixed-size repeated-edit case separates elapsed-time effects from growing payload. Report per-update CPU cost, main-thread edit-through-layout latency (median, p95, maximum), physical footprint, disk reads/writes, and measured accelerator intervals. Forced-layout timing is a responsiveness proxy, not key-to-photon latency. The typing target is roughly one 60 Hz frame (16.7 ms) for ordinary edits; a 100 ms per-key delay is not acceptable merely because average CPU falls.

Use one comparison figure with elapsed-time and payload-size columns, shared task colors, and separate rows for CPU, memory, disk writes, and device activity. Overlay comparable workloads; leave unmeasured device intervals open. Short GPU/Neural Engine/Core ML probes remain separate from unprofiled timing runs. Stop a screening run at 2 GiB footprint, a two-second synchronous update, or its bounded wall-time deadline. Passing these checks establishes a tested range on this Mac, not a universal content limit.

## Rendering and saving

The blank-transcript screenshot is approximately **11:43:17 UTC / 21:43:17 local on October 2**. Surrounding ten-second app CPU samples were **56.5%** and **50.4%**; that minute ranged from 48.8% to 62.5%. A later sample reached 73.9% at 11:44:14, but timing alone cannot link it to the blank view. Switching to another meeting and back rendered quickly. The foregrounding failure was not reproduced.

The last first-phase Instruments trace completed at 11:23:10 UTC. Scheduled traces stopped at the planned two-hour cutoff while ordinary resource samples continued. No stack, frame, hang, or redraw trace covers the blank state. Ten-second CPU averages can hide a brief main-thread stall; low average CPU does not rule out drawing or invalidation failure.

In the first phase, compared early and late quiet windows had mean main-thread CPU of **20.9% and 22.2%**. Layout accounted for about half of main-thread samples; stream refresh about 1.5–2.0%. These inclusive categories overlap. They identify layout as a useful investigation target without proving that old transcript rows are re-rendered or that recording age caused the total CPU increase.

| Save | Sampled app CPU peak near save | Physical footprint before → observed peak | Trace coverage |
| --- | ---: | ---: | --- |
| First speaker-enabled run | 146.6% | ~277 → 1,493.7 MiB | Started after the largest spike; cause unresolved |
| Transcription only | 58.9% | ~349 → 382.2 MiB | Ended about eight seconds before audio finalization |
| Recording only | ~30%, then ~4% after stop | ~345 → ~345 MiB | 120.9-second trace spans finalization |
| Repeated speaker-enabled run | 127.1% | ~375 → ~1,015 MiB | Intended save trace ended at 15:01:36; Stop was clicked at 15:02:07.669 |

These sampled peaks are lower bounds on instantaneous peaks. The recording-only trace includes idle time and accessibility work after saving, so its whole-trace CPU average is not a save-only cost. A transient **478.4 MiB** recording-only footprint peak occurred around a scheduled capture, then fell to 331.4 MiB ten seconds later. It was not sustained; its allocation cause remains unknown.

The repeated speaker-enabled hour had ordinary app CPU median **47.0%** (p95 **51.6%**, 197 samples), readable speech-service median **6.5%**, and main-thread trace median **22.5%**. Layout represented 48.8% of sampled main-thread CPU. Its footprint fell from a startup high around 495 MiB to about 268 MiB, remained around 269–279 MiB during minutes 20–40, then rose during Notes and instrumentation workloads. That is not evidence of a steady leak.

<details>
<summary>Earlier partial interaction captures and accelerator probes</summary>

![CPU and memory during Notes, save, and navigation, with discrete accelerator measurements and capture gaps.](assets/2026-10-02-recording-endurance/workload-detail.svg)

## Notes and navigation workloads

Notes testing added 40 synthetic paragraphs and four image attachments: two images pasted twice. A later saved-Notes workload added six more typing bursts, about 815 characters each. Forty typing calls took about 60 seconds. The first 90-second all-device capture exceeded the artifact cap while finalizing and could not be recovered. Its CPU/memory samples remain, but that initial typing attempt has no usable stacks or accelerator measurements. The complete-task follow-up above later captured the full input window.

The first image paste fell after its capture ended. A repeated paste at 14:58:52.041 was covered by the 14:58:36.622–57.774 trace: app/main CPU averaged **42.1% / 12.3%** of one core. Sampled Notes image handling was 11 ms and paste handling 3 ms; layout was 700 ms and accessibility work 318 ms. Inclusive categories overlap and do not measure input latency. These observations do not reproduce a sustained Notes rendering freeze.

The later saved-Notes typing trace ran 15:12:59.380–15:13:20.560, covering only the first 7.28 seconds of the 15:13:13.277–46.088 input burst. App/main CPU averaged **27.6% / 26.6%** over the whole trace. Notes change handling sampled 1.529 seconds, image handling 1.419 seconds, and layout 685 ms. Those inclusive categories overlap; this identifies Notes work during input but does not measure the full burst or key-to-paint latency.

The capture intended for final save ran 15:01:15.394–36.422, but Stop was clicked at **15:02:07.669**. Treat its values as pre-save only. Later ordinary samples retain the save memory peak; no corresponding stack trace covers it.

A later capture labeled Summary-visible did **not** run Summary generation: automatic approval review blocked the external-provider request. It is an idle blocked-attempt observation, not evidence about Summary performance. A 30-second navigation attempt also failed during trace finalization; its CPU/memory samples remain, but no verified accelerator or stack measurements do. A later 20.927-second capture covered switching away from a saved meeting: app/main CPU averaged 6.78% / 6.72%, with no observed app GPU or ANE activity. The return occurred after the capture ended. This is saved-meeting navigation, not navigation during Summary generation. That initial attempt did not test Summary generation. The authorized follow-up below supersedes the pending status.

## Summary generation follow-up

![Local app CPU and footprint during three authorized Summary requests, with discrete GPU and Neural Engine captures.](assets/2026-10-02-recording-endurance/summary-resource.svg)

On October 3, after approval for the configured OpenRouter provider, Summary generation reproduced local app CPU near one core: ten-second samples reached **93.3%** on the first request and **100.6%** on the second. CPU returned below 0.1% after the third run. This reproduces temporary high local CPU, not continuous one-core use throughout generation. Physical footprint peaked at **537.5 MiB** during the follow-up.

In these initial short probes, the strongest CPU spikes fell outside the Instruments windows. The complete-task follow-up above subsequently captured and attributed the main-thread spikes. Startup traces also contain substantial accessibility inspection: 2.261 and 2.155 seconds of sampled main-thread work. The later capture avoided UI polling and recorded 193 ms of Markdown rendering, 204 ms of Markdown update work, 995 ms of layout, and 11 ms of accessibility work over 20.967 seconds. These inclusive categories overlap. Those initial probes alone did not establish the cause; the later full-task evidence above identifies dominant view-graph/layout work.

All three captures observed **zero app GPU and system Neural Engine activity**, with valid empty Core ML tables. System GPU active wall time was 0.20–2.47%. The provider performs generation remotely; these measurements describe local client processing and rendering, not server inference.

| Capture | Actual UTC interval | App / main CPU, % of one core | Workload coverage |
| --- | --- | ---: | --- |
| First request startup | 01:07:13.610–34.809 | 22.23 / 21.58 | Request began 01:07:23.666; trace ended before the 93.3% sample and observed completion |
| Second request startup | 01:08:36.649–57.637 | 20.49 / 20.09 | Request began 01:08:52.859; trace ended before Notes/Summary tab changes and the 100.6% sample |
| Later output, no UI polling | 01:10:54.420–01:11:15.387 | 14.05 / 13.55 | Request began 01:10:34.160; trace covers later output and return toward idle, not the complete request |

Notes and Summary tabs were changed during the second request, but after its trace ended. Saved meetings were switched after generation completed. Those interactions therefore lack overlapping stack captures; no measured input-latency or navigation-during-streaming conclusion is claimed. Use the [repeat runbook](../../apps/client-macos-swift/docs/PERFORMANCE_TESTING.md) to align a short CPU/hang capture with incoming output and measure visible-versus-hidden Summary at fixed output sizes and chunk cadence. Keep heavyweight GPU tracing separate if it prevents covering the relevant UI interval.

The final Summary was verified in the app and persisted in `summary.md` (4,027 bytes). The three new raw traces were removed after aggregate verification; numeric results, TOCs, export hashes, and private provenance remain. This follow-up supersedes the earlier pending-approval status; the earlier blocked attempt remains an idle observation.


</details>

## Recording integrity

Both tracks in each completed phase have matching durations, valid endings, and no observed Ogg page sequence gaps or ffprobe errors. These are container and duration checks, not full decoded-audio or recognition-accuracy validation. CRCs were not checked.

Part 1's saved live transcript has startup coverage gaps under 1.4 seconds, plus 9.7 ms and 38.9 ms gaps. Part 2 has only two startup transcription gaps, 0.919 and 0.860 seconds. These coverage flags do not establish missing saved audio. Part 3 intentionally has no live transcription.

## Detailed measurements

<details>
<summary>Phase measurements</summary>

| Phase | Monitored minutes | App CPU median / p95 | Footprint first → last | Main CPU median, quiet profiles | Readable speech CPU median | Accelerator captures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Transcription + speakers · First 120 min | 120.0 | 45.9% / 55.1% | 198.0 → 264.6 MiB | 21.7% | Not measured | 1 |
| Transcription + speakers · Extension | 17.2 | 52.5% / 57.6% | 263.0 → 275.5 MiB | Not measured | Not measured | 0 |
| Transcription only · First 60 min | 60.0 | 40.9% / 48.5% | 263.6 → 343.5 MiB | 16.2% | 8.5% | 3 |
| Transcription only · Extension | 1.0 | 39.6% / 42.3% | 344.4 → 349.5 MiB | Not measured | 6.9% | 0 |
| Recording only · First 60 min | 60.0 | 30.3% / 33.8% | 381.9 → 345.1 MiB | 9.4% | 0.0% | 12 |
| Recording only · Extension | 3.9 | 31.7% / 33.1% | 345.1 → 345.4 MiB | Not measured | 2.0% | 0 |
| Transcription + speakers, repeat · First 60 min | 59.8 | 47.0% / 51.6% | 494.8 → 375.0 MiB | 22.5% | 6.5% | 10 |
| Transcription + speakers, repeat · Extension | 0.0 | Not measured / Not measured | 373.9 → 373.9 MiB | Not measured | Not measured | 0 |

CPU summaries exclude capture/export intervals, declared analysis/UI exclusions, invalid restart deltas, and samples spanning gaps. Profile-note exclusions are omitted from quiet profile comparisons. Memory retains observed capture and save peaks. Readable speech CPU sums available speech-service processes; protected counters are unavailable and first-phase service coverage is missing.

</details>

<details>
<summary>Individual accelerator observations</summary>

| Phase | Probe | Trace seconds | App GPU active | System GPU active | ANE active | GPU app / ANE intervals | Core ML event rows |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Transcription + speakers | labels-mid | 20.807 | 0.866% | 23.495% | 16.614% | 298 / 101 | 0 |
| Transcription only | transcription-early | 20.814 | 0.000% | 21.044% | 2.004% | 0 / 42 | 0 |
| Transcription only | transcription-mid | 20.810 | 0.000% | 19.784% | 2.043% | 0 / 42 | 0 |
| Transcription only | transcription-late | 21.127 | 0.000% | 17.185% | 1.778% | 0 / 43 | 0 |
| Recording only | recording-minute-00 | 20.944 | 0.000% | 11.923% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-05 | 21.165 | 0.000% | 6.584% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-10 | 20.825 | 0.000% | 3.219% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-15 | 20.943 | 0.000% | 1.715% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-20 | 20.846 | 0.000% | 1.880% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-25 | 20.866 | 0.000% | 0.224% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-30 | 20.829 | 0.000% | 3.745% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-35 | 20.975 | 0.000% | 13.148% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-40 | 20.929 | 0.000% | 3.825% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-45 | 20.998 | 0.000% | 1.796% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-50 | 20.832 | 0.000% | 1.765% | 0.000% | 0 / 0 | 0 |
| Recording only | recording-minute-55 | 20.961 | 0.000% | 2.247% | 0.000% | 0 / 0 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-00 | 21.064 | 0.801% | 4.357% | 16.071% | 294 / 103 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-05 | 20.946 | 0.812% | 4.969% | 16.166% | 296 / 102 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-10 | 21.351 | 0.777% | 4.176% | 16.966% | 297 / 104 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-15 | 20.920 | 0.830% | 10.284% | 16.233% | 305 / 103 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-20 | 21.516 | 0.786% | 4.979% | 16.337% | 295 / 102 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-25 | 20.994 | 0.792% | 5.738% | 16.790% | 292 / 100 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-30 | 20.943 | 0.802% | 5.139% | 16.281% | 287 / 101 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-35 | 20.834 | 0.808% | 9.164% | 15.712% | 289 / 99 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-40 | 20.952 | 0.841% | 9.067% | 16.610% | 295 / 103 | 0 |
| Transcription + speakers, repeat | labels_repeat-minute-45 | 21.168 | 0.805% | 9.056% | 16.413% | 297 / 103 | 0 |

App GPU is process-attributed; system GPU includes browser/compositor rendering. Neural Engine activity lacks model attribution. Empty Core ML event tables do not establish absence of model execution. Do not add device percentages or overlapping process fractions.

</details>

<details>
<summary>Measurement coverage</summary>

| Phase | Ordinary CPU samples | Quiet CPU captures / seconds | Accelerator observed seconds | Speech coverage starts at minute |
| --- | ---: | ---: | ---: | ---: |
| Transcription + speakers · First 120 min | 557 | 23 / 460.0 | 20.8 | Not measured |
| Transcription + speakers · Extension | 102 | 0 / 0.0 | 0.0 | Not measured |
| Transcription only · First 60 min | 229 | 11 / 220.0 | 62.8 | 11.0 |
| Transcription only · Extension | 2 | 0 / 0.0 | 0.0 | 60.1 |
| Recording only · First 60 min | 255 | 11 / 229.9 | 251.1 | 2.5 |
| Recording only · Extension | 23 | 0 / 0.0 | 0.0 | 60.1 |
| Transcription + speakers, repeat · First 60 min | 197 | 10 / 210.7 | 210.7 | 1.6 |
| Transcription + speakers, repeat · Extension | 0 | 0 / 0.0 | 0.0 | Not measured |

Monitored minutes are not the saved-audio duration. CPU profile percentages use each stored duration; legacy CPU-only rows store nominal 20-second durations, while combined rows use actual TOC durations. Main-thread points are sampled CPU, not frame or input latency.

</details>


<details>
<summary>Recorded context</summary>

- 2026-10-02T12:49:14+00:00: Playback moved to direct audio players. Browser playback paused; desktop client closed around this transition. System GPU rendering workload changed, limiting cross-phase GPU totals.
- 2026-10-02T12:48:00+00:00: Background build and preview observed. Approximate observation interval; background load changed near the transcription-phase end.
- 2026-10-02T11:43:17+00:00: Blank transcript reported after foregrounding. Nearby ten-second app CPU samples were 56.531% and 50.442%. No overlapping Instruments capture exists; cause and frame/input latency are unmeasured.

</details>


<details>
<summary>Manual capture values and actual coverage</summary>

| Workload | Actual seconds | Trace completed | App CPU, % core | Main CPU, % core | App GPU, % time | System GPU, % time | System ANE, % time | Core ML events |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Notes before image paste | 21.16 | Yes | 37.59 | 8.16 | 0.796 | 19.069 | 16.977 | 0 |
| Notes image paste | 21.15 | Yes | 42.09 | 12.28 | 0.640 | 15.425 | 16.897 | 0 |
| Before Stop (save not captured) | 21.03 | Yes | 42.55 | 13.06 | 0.669 | 15.920 | 16.570 | 0 |
| Idle: Summary request blocked | 21.18 | Yes | 0.08 | 0.05 | 0.000 | 16.865 | 0.000 | 0 |
| Saved meeting switching | 20.93 | Yes | 6.78 | 6.72 | 0.000 | 17.241 | 0.000 | 0 |
| Saved Notes typing (partial burst) | 21.18 | Yes | 27.62 | 26.63 | 0.002 | 17.495 | 0.000 | 0 |

CPU and memory samples include instrumentation and UI interaction. Device marks are actual capture-window averages, not continuous utilization. App GPU is included in system GPU. ANE is system-wide; these measures cannot be added. Missing intervals remain unmeasured. Zero Core ML events does not rule out inference through another backend.

</details>

## Method and limits

The evaluation addresses long-recording resource use and reported rendering delays. App CPU deltas, physical footprint, RSS, disk I/O, recording size, and free space are sampled about every ten seconds. CPU counters are converted from Mach ticks using the machine timebase and checked against process CPU totals. A separate speech-service sampler began during Part 2; protected counters remain unavailable, not zero.

Parts 1–2 use 20-second CPU captures every five minutes; Part 2 adds early, middle, and late all-device probes. Parts 3–4 schedule CPU, GPU, Neural Engine, and Core ML together every five minutes. Part 4 completed ten regular captures; manual Notes workloads occupied the final two scheduled slots. Capture/export intervals and documented analysis or UI activity are excluded from ordinary CPU summaries. The combined captures use actual trace durations; older CPU-only summaries use nominal 20 seconds. Samples are correlated observations, not independent trials.

The app GPU rows identify Nemotron inference commands. Neural Engine rows are system-wide and cannot identify a model or process. Empty Core ML model-event tables do not mean no Core ML execution. Model compute settings permit devices; observed traces establish which activity was actually captured.

Playback moved from the browser to direct `ffplay` processes at 12:49:14 UTC. The Rust app and playback page were then closed; a script queues subsequent meetings. This changes the background rendering workload. Sources, system activity, and retained model caches also change across sequential phases, so differences are descriptive rather than controlled feature-cost estimates. A separate build and synthetic preview were observed near the end of Part 2.

A 154-second monitor interruption in Part 1 and its first invalid restarted CPU delta are excluded. Part 1 overran after a handover misunderstanding. Part 3 overran because a watchdog reminder queued while the parent turn was inactive. Planned durations are compared separately from extensions. For Part 4, a sub-agent owned Stop; UI/tool delays moved the actual click to 15:02:07.669, after the intended save capture ended. The intended save capture therefore measures pre-save activity only.

## Retention and restoration

Raw artifacts stay outside the repository under `/private/tmp/gday-longrun-20261002`. The artifact interruption threshold is **8 GiB**, with a **20 GiB free-space floor**. Two-second polling and a 20-second graceful-stop interval allow transient overshoot during finalization; this is not a hard disk quota. Each combined capture is exported and validated immediately. Numeric aggregates and provenance are retained; disposable exports and verified intermediate traces are removed. The first and latest successful raw trace are retained separately for Parts 3 and 4. Earlier-phase references are retained. User-authorized cleanup removed verified manual raw traces after aggregation and an unrecoverable failed Notes trace. The 90-second Notes and 30-second navigation attempts exceeded the threshold during trace finalization and failed. The manual helper now accepts exactly 20 seconds.

Settings were restored: after-recording Summary and to-do generation are on; live transcription, speaker labeling, association, microphone, and system audio are on. Recording measurements are finished. Monitor, speech-service sampler, playback queue, players, tracing, and keep-awake processes were stopped; shutdown was verified. The user later approved OpenRouter, and the Summary follow-up was completed; the restarted samplers were stopped.

## Source fixes versus the measured build

A read-only audit at 14:27 UTC found source commit `8fd4a75`, newer than the running app. Its [saved-transcript changes](2026-10-03-saved-transcript-segments.md) remove full event replay, hashing, and full draft rewriting from a healthy stop, and change ordinary reopening to read the saved projection. Those paths are fixed in source; this experiment does not validate their latency or memory benefit, nor prove they caused the earlier spike.

No newer Notes, Summary, or foreground-layout repair was found in that audit. Summary publication is already throttled to about 100 ms, but changed text still replaces the complete attributed document. Notes edits publish Markdown and invalidate layout, with image normalization debounced by 450 ms. These are paths to measure, not established causes. A further read-only check at 15:11 UTC still found HEAD `8fd4a75` with no uncommitted application code.

A final source check during the Summary follow-up found no newer committed app implementation. Concurrent uncommitted changes corrected transcript filenames in data-event records and tests; they were not part of this measured build or this documentation commit.

## Technical debt and follow-up

The baseline experiments preceded the code repairs documented below. These measurement limitations remain:

- **Foregrounding and save diagnosis:** capture UI/hang and allocation evidence before reproducing the blank transcript or pressing Stop & Save. Current CPU profiles do not establish the proposed input-latency target.
- **Sequential workloads and caches:** repeat fixed synthetic material in fresh processes, with no competing builds, for controlled mode comparisons.
- **Sparse first-phase accelerators:** the final repeat improves coverage; it cannot reconstruct missing historical device activity.
- **Rolling trace retention:** intermediate detailed stacks are discarded after numeric verification to bound disk usage. Re-capture anomalies that need deeper stack/allocation analysis.
- **Summary generation and Notes:** complete-task profiles identify main-thread view/layout and Notes image/change costs. The synthetic repair comparison is above; repeat provider-driven full-window tasks and measure input latency separately. See the [repeat runbook](../../apps/client-macos-swift/docs/PERFORMANCE_TESTING.md) and [performance evaluation plan](2026-10-02-performance-evaluation-plan.md).

SVG text is embedded as vector outlines to avoid viewer font substitution. The exported SVG is rasterized only for visual checking; the worklog uses the SVG.

## Summary publication repair — October 3

**Problem:** Each partial Summary update published a change through `MeetingStore`, notifying views throughout the library even when Summary was hidden. Complete-task traces support this explanation for repeated view-graph and layout work; Markdown parsing was a smaller measured component.

**Implemented solution:** `MeetingStore` now owns a separate `SummaryDraftState`. Only the Summary document child observes its draft dictionary. The provider's 100 ms delivery cadence, task ownership, saved-result validation, and cleanup remain unchanged. An absent draft displays the saved summary; an empty draft displays “Writing summary…”. Removing the draft after success, cancellation, or failure restores the saved document and its task controls. Preview and existing streaming tests use the same state object.

**Reasoning and design:** Isolate the frequently changing state using the same pattern as recording meters. The inspected existing Summary screenshot established an unchanged layout: heading and action above the document card, with the same tabs, selection, citations, and task controls. This removes unnecessary library notifications without delaying visible text or changing Markdown rendering.

**Technical debt:** No duplicate storage or compatibility property was added. The existing whole-document Markdown renderer remains a secondary cost; a controlled comparison is needed before designing incremental rendering. The shared draft dictionary would notify every Summary document in a future multiwindow interface; that design should introduce a separate observable for each meeting. The current app has one main window.

**Validation:** The isolated prototype on `dcc4679` passed 21 tests in `SummaryDraftStateTests`, `SummaryStreamingTests`, `AutomaticSummaryTests`, and `BackgroundJobTests`. The observer test recorded 103 draft notifications for creation, 100 replacements, a second draft, and removal, with zero `MeetingStore` notifications. Formatting, lint, and diff checks passed. The release build, property-list validation, signing, and strict signature verification passed. Integration onto `847b840` applied without conflicts. Existing Command Line Tools linker warnings report missing Developer framework/library search paths; the toolchain update remains the follow-up. Cold bundled-autotools configuration also probes obsolete `-single_module`; update those upstream scripts with the next pinned dependency refresh. No application API deprecation warning occurred. The integration and synthetic checks below supersede the prototype’s pending validation. The installed app has not been replaced.

**Controlled publication comparison:** `SummaryPerformanceTests.hiddenSummaryPublication` uses the actual library view in an unshown native window, with 26 synthetic meetings. It forces layout and drawing on each run-loop iteration and delivers identical growing draft text at 10 Hz. Three alternating pairs compare document-only publication with the same updates plus the old library-wide notification. Each measured condition lasts four seconds. Main-thread CPU was 1.2%, 1.3%, and 1.3% of one core with document-only updates, versus 30.1%, 30.3%, and 28.6% with the library notification restored. Process CPU was 2.1–2.4% versus 29.1–30.9%. This debug-build experiment isolates the cost of the removed notification in a synthetic hidden-Summary workload. It does not measure provider duration, visible Summary rendering, keystroke latency, or the installed app’s improvement. Run it alone with `GDAY_PERFORMANCE=1` and the `SummaryPerformanceTests` filter to avoid concurrent test interference.

**Integration and UI check:** The focused 21-test run and signed release build were repeated successfully on `847b840` with the Summary changes. An isolated preview bundle used synthetic data and a separate application identifier. Captured screenshots in System/light and Dark appearances matched the intended Summary heading, action, tabs, and document card. Native keyboard selection covered all 30 synthetic paragraphs, and navigating to Notes and back preserved the draft. The preview fixture had finished delivering its 1 Hz fragments before inspection, so these checks do not establish live-update smoothness. Narrow windows, inactive-window appearance, citation playback, task toggles, and a visible 10 Hz CPU comparison were not exercised in this UI check; streaming completion and cancellation remain covered by automated tests. The installed app and user library were unchanged.

## Notes repeated-work repair — October 3

**Problem:** The complete typing trace identifies repeated text work rather than attachment decoding. Of 20.071 main CPU-seconds during input, image-presentation paths include 3.873 seconds of whole-document string comparisons and 1.443 seconds of reference parsing. Parsing includes 994 ms scanning code ranges, 293 ms matching regular expressions, and 81 ms compiling them. The comparisons repeatedly traverse and normalize Unicode text. No attachment thumbnail/info or ImageIO decoding samples appeared in that window. Inclusive categories overlap.

**Implemented solution:** Image presentation invalidates cached references on completed character edits. Attribute-only changes and unchanged layout reuse the references, while width and asset metadata checks still refresh images. Native edit proposals rebase ranges only when they match the completed edit; grouped edits use reference reconciliation so an unchanged image is not mistaken for deleted text. This avoids whole-document equality checks and duplicate parsing between input and layout.

**Reasoning and design:** Keep the observed Notes layout and behavior: editable paragraphs, timestamp gutter, image placement, selection, and undo. Invalidation follows actual edits rather than a delayed UI refresh. Existing image undo and duplicate-reference tests passed, along with new grouped-edit, Unicode range, same-document replacement, and external-asset checks: 61 Notes tests in total.

**Controlled image-path comparison:** A release benchmark uses 300 synthetic Unicode paragraphs, four image references, 100 character edits, and 2,000 unchanged reconciliations. Three baseline runs took 2.674, 2.595, and 2.612 seconds; fixed runs took 0.264, 0.257, and 0.251 seconds. Median elapsed time fell 90.2% for this path. This is not whole-window typing latency or a 90.2% reduction in total app CPU.

**Technical debt and remaining work:** The capacity comparison and later styling/gutter repairs are documented at the top of this file. Cursor hit testing, block normalization, and library updates on edits remain relevant follow-ups. The cache is derived state, not a second source of Notes content. Combined release validation passed; final full-window visual/input verification remains blocked by Computer Use access.


### Completed Notes component comparison

A fresh release test process requested one character at 10 Hz for 25 seconds into approximately 100 KiB of synthetic Notes with four image references, then waited five seconds and flushed Notes. Both runs completed. The actual Notes workspace and persistence code were used; the library sidebar was excluded. No build or profiler ran concurrently.

| Metric | Before image cache | With image cache |
| --- | ---: | ---: |
| Main-thread CPU during input, % of one core | 69.6 | 36.9 |
| Process CPU during input, % of one core | 70.5 | 38.5 |
| Edit and layout, median ms | 33.12 | 19.92 |
| Edit and layout, p95 ms | 34.05 | 31.93 |
| Edit and layout, maximum ms | 48.16 | 38.23 |
| Completed edits | 245 | 241 |
| Peak physical footprint, MiB | 81.34 | 84.24 |
| Process disk writes, KiB | 112 | 144 |

The cache reduces CPU substantially, but the p95 remains above the 16.7 ms ordinary-edit target. The timed action covers insertion, a 1 ms run-loop opportunity, and forced layout/drawing; deferred styling can occur afterward, so it is not hardware key-to-photon latency. These are single runs. Notes schedules its next delivery relative to the previous start; count divided by actual input duration is the achieved rate, and its skipped counter misses accumulated scheduling drift. GPU, Neural Engine, and Core ML were not captured in this pair and remain unmeasured.

The earlier instrumented baseline terminated after 11.4 seconds and is excluded. Its Instruments export also contained an invalid XML control character from the inherited shell prompt. Subsequent test launches remove prompt variables; neither failure is treated as evidence of zero accelerator activity or a completed typing test.
