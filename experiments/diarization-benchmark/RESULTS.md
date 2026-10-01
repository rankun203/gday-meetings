---
title: Local diarization benchmark results
date: 2026-10-01
status: experimental
scope: standalone-coreml-diarization
---

# Local diarization benchmark results

Both model pipelines built and processed the same four local recordings on an Apple M1 Max with 64 GiB RAM. This establishes local feasibility, not speaker-label accuracy or production readiness. The app package has no inference dependency added.

The [README](README.md) records model pins, build commands, and replay behavior. Measurements used macOS 26.6.2, Swift 6.4, Core ML `.all` (Community-1 FBank uses `.cpuOnly`), and serial processes at `nice 10`. The Mac was also recording; early runs overlapped release builds. These are practical observations, not isolated hardware rankings.

## Full recordings

The table reports end-to-end process wall time, including model setup and audio preparation. Internal inference-only timing is unsuitable for direct comparison because the two pipelines decode audio at different stages.

| Anonymous sample | Duration | Community-1 | Nemotron `.low` | Community-1 output speakers | Nemotron active slots |
| --- | ---: | ---: | ---: | ---: | ---: |
| A | 54.51 min | 16.95 s | 267.18 s | 4 | 4 |
| B | 61.89 min | 17.45 s | 294.35 s | 2 | 3 |
| C | 9.95 min | 3.88 s | 48.11 s | 2 | 2 |
| D | 51.39 min | 15.19 s | 255.48 s | 5 | 8 |

All eight runs completed and matched the input duration. Nemotron uses its low-latency streaming preset even in saved-file mode; this is not a comparison with its separately exported offline preset. Its saved-file mode already feeds 20 ms chunks through persistent state, so an accelerated replay with the same settings would repeat the same computation. No independent equivalence claim is made.

Nemotron counts slots active at probability 0.5 or higher for at least 0.5 seconds. Community-1 counts clustered output speaker IDs. These counts are not interchangeable measures of accuracy. In sample B, Nemotron's third slot was active for only 1.47 seconds. Sample D occupied all eight Nemotron slots; that does not prove the recording has exactly eight people.

These full-file results came from the pre-review measurement binaries, retained privately by hash. Later CLI validation, result identity, cleanup, timestamp reporting, and live-delay instrumentation changes must not silently relabel these results as runs of a new binary. The inference configuration and model snapshots remain the same.

## Resources and startup

| Measurement | Community-1 | Nemotron `.low` |
| --- | ---: | ---: |
| Selected model files | 21.60 MB | 199.12 MB |
| Full-file process peak RSS | 378–716 MB | 71–84 MB |
| Full-file process peak physical footprint (`time -l`) | 713–825 MB | 55–57 MB |
| Model-load time in these warmed process starts | 0.14–0.19 s | 0.14–0.19 s |

MB denotes decimal bytes. RSS and physical footprint are different accounting measures; neither establishes total system memory used by Core ML services or the Neural Engine. Do not infer device utilization from `.all`.

Initial Nemotron setup took 65.89 and 68.67 seconds in earlier process starts. Core ML caches were not cleared, so these are observed startup measurements rather than a controlled cold-cache benchmark. Later loads were much faster. A product needs asynchronous setup and a measured first-use experience rather than assuming the warmed load time.

## Live replay

Paced replay supplies audio on its original schedule in 20 ms blocks. Model loading occurs before the replay clock starts. Delay measurements distinguish arrival, output availability, and backlog. First probability output is not a stable speaker label.

Community-1 replay is a causal adapter: it recomputes the trailing 30 seconds every 10 seconds. It does not preserve identities between windows. Its local labels can change; production live labels would require additional identity matching and revision handling.

Four one-minute paced excerpts completed with duration validation. Both models used the same selected window for each sample. The values below use the final timing definitions: output availability is captured when the pipeline returns, before exporting segment JSON. It is not the time a label appears in the app.

| Sample | Pipeline | First output | Additional output delay, p95 | Worst simulated backlog |
| --- | --- | ---: | ---: | ---: |
| C | Nemotron `.low` | 1.205 s | 84.85 ms | 145.36 ms |
| D | Nemotron `.low` | 1.228 s | 77.42 ms | 167.55 ms |
| C | Community-1 window adapter | 10.197 s | 309.76 ms | 312.27 ms |
| D | Community-1 window adapter | 10.183 s | 355.77 ms | 364.23 ms |

Additional delay is measured after the corresponding input/window is scheduled to arrive. It excludes the required input buffer and is not total caption latency. The ten-second first-window schedule is chosen by this Community-1 adapter, not a claimed intrinsic model limit. All four excerpts finished in 60.12–60.35 seconds after the replay clock started. These short runs show headroom, not an hour-long paced soak guarantee.

All four complete recordings also passed accelerated Community-1 window replay: 60–372 updates per recording, taking 18.12–102.13 seconds. Samples A–C used the earlier measurement binary; D used the corrected timestamp binary. Timing instrumentation differs, so these full-file replay times are functional observations rather than a controlled ranking.

A separate 10 ms overlap check found that the first two Community-1 windows for sample C disagreed on speech/speaker assignments for 4.58 seconds of overlapping audio, even after speaker permutation matching. This is a consistency observation, not an error rate against ground truth. Cross-window identity matching and revisions remain product work.

Final paced executable hashes:

- Nemotron: `0a6271dba828f1807661b852c2d48e91e089da594f6716825ec6e4c925b12a38`.
- Community-1: `ee3def7b1fc1f4a2cfe2961906f3cab1a745ed338ee442cf7cc7ac64c29c234c`.

A preliminary Nemotron timing revision included segment-export work in its completion timestamp. Its two paced runs were superseded by repeats using the hash above; those preliminary delays are not used in this table.

## Interpretation and limits

Community-1 is the stronger performance candidate for after-meeting processing in these runs. Nemotron is the native streaming candidate. Both need manually checked speaker annotations before choosing on accuracy.

Existing meeting labels are unverified annotations. They contain 2, 3, 6, or 11 label IDs, not necessarily that many people. One reference has extensive overlapping labels and is unsuitable as ground truth without review. Microphone/system-track mixing and approximate alignment can introduce overlap or echo. No diarization error rate is claimed.

The standalone package pins FluidAudio and disables its Rust text-processing trait. Runtime checks report no linked native Rust normalizer, but SwiftPM still downloaded the optional artifact during resolution. FluidAudio also compiles C/C++ helpers and its full Swift library. An incremental Swift Build stall was observed and recovered in the isolated checkout; supported macOS/toolchain matrix validation remains necessary before adopting this dependency in the app. Intel, battery use, sustained thermal behavior, and combined live Apple Speech plus diarization quality are untested.

Audio, input manifests, reference intervals, raw outputs, and binary-specific receipts remain outside Git. Only these anonymous aggregates are included here.

## Agreement with saved Rust annotations

The first exploratory comparison uses sample A, whose saved extraction and current audio durations differ by about 10 ms per track. The historical provider receipt is absent: current settings point to RunPod and the artifacts match its extraction protocol, but this does not independently prove which host processed that meeting. These are existing extraction annotations, not a verified RunPod accuracy benchmark.

| Scoring region | Community-1 disagreement | Nemotron disagreement |
| --- | ---: | ---: |
| Annotated speech, overlap included, no collar | 18.08% | 23.11% |
| Annotated speech, overlap excluded, no collar | 16.32% | 22.03% |
| Annotated speech, overlap included, ±250 ms collar | 17.45% | 23.41% |
| Annotated speech, overlap excluded, ±250 ms collar | 16.08% | 22.44% |

Lower means closer agreement with these saved annotations. The denominator is reference speaker-seconds after exclusions, not total recording time. A maximum-duration one-to-one assignment removes arbitrary label-name differences. Six existing track-scoped labels remain distinct; person assignments were not used to merge labels. Unannotated gaps are excluded rather than assumed silent. The uncollared overlap-inclusive region covers 2,752.01 seconds of audio and 2,815.90 reference speaker-seconds. Most disagreement is speech coverage: Community-1 has 399.79 missed and 109.29 confused speaker-seconds; Nemotron has 479.94 missed, 59.22 extra, and 111.71 confused speaker-seconds. Transcript segments may include pauses, so these are not confirmed model errors.

Community-1 is closer on this sample, but this single provisional reference cannot establish an accuracy ranking. Private reports identify disagreement intervals for listening; no listening adjudication has been completed. Other selected references need timing or overlap review before their scores can support a comparison. The user-selected follow-up below supplies a new reference set for further review.

Read-only decoding checks found that both current FFmpeg Opus decoders reproduce the prepared duration for the two mismatched samples, and packet timestamps have no gaps. This rules out a simple current decoder-choice or packet-gap explanation; it does not recover the historical worker input timeline. No offset or time stretching was fitted to improve agreement.

## User-selected single-track follow-up

Both models completed four additional full-track runs each, totaling 173.59 minutes of identical input per model. Three inputs used system audio and one used a room microphone; tracks were not mixed. Exact source mappings, per-meeting measurements, and predictions remain in ignored `tmp/`.

Community-1 used 52.66 seconds total end-to-end wall time; Nemotron `.low` used 790.83 seconds. Process peak RSS ranged from 530.91–690.77 MB and 84.07–96.45 MB respectively. These use the final executable hashes above, warmed model caches, and serial runs on the same Mac. They are observations, not isolated hardware benchmarks.

Two saved references passed the decoded-duration screening check. With one optimal label mapping per recording, pooled disagreement was:

| Scoring policy | Community-1 | Nemotron `.low` |
| --- | ---: | ---: |
| Annotated speech, no boundary exclusion | 17.48% | 28.24% |
| Annotated speech, ±250 ms boundary exclusion | 17.22% | 27.73% |

The denominator sums reference speaker-seconds across the two recordings after fitting mappings separately. These references contain no cross-label overlap, so including or excluding reference overlap produces the same values; this does not prove the audio has no overlapping speech. The other two reference scores remain withheld due to historical/current decoded-duration differences. Person-linked labels merge only when existing segment assignments, embedding assignments, and local profiles consistently identify the same person.

The scores establish agreement with saved annotations, not superiority over the server. Forty independently sampled 20-second clips and twelve separately selected diagnostic clips are ready for blind annotation. All templates remain unreviewed. The [evaluation procedure](EVALUATION.md) and scoring tools allow the server itself to make errors against independently reviewed speech, silence, and speaker labels. No human-reviewed accuracy or live-label quality claim is available yet.
