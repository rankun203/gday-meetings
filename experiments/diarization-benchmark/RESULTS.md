---
title: Local diarization benchmark results
date: 2026-10-01
status: experimental
scope: standalone-coreml-diarization
---

# Local diarization benchmark results

Both model pipelines built and processed the same four local recordings on an Apple M1 Max with 64 GiB RAM. These initial runs establish local feasibility. The human-reviewed comparison below adds an accuracy assessment on selected local meeting samples; production readiness remains untested. The benchmark ran independently of the app package. The later app integration is described in the [live transcription design](../../docs/design/live-transcription-research.md).

The [README](README.md) records model pins, build commands, and replay behavior. Measurements used macOS 26.6.2, Swift 6.4, Core ML `.all` (Community-1 FBank uses `.cpuOnly`), and serial processes at `nice 10`. The Mac was also recording; early runs overlapped release builds. These are practical observations, not isolated hardware rankings.

## Human-reviewed local meeting samples

One reviewer completed 97 clips from eight local meeting samples. The primary comparison uses 66 independently sampled 20-second clips (21.92 reviewed minutes after uncertainty exclusions). The remaining clips were selected for speaker coverage or disagreement diagnosis and are scored separately. Saved server output and both local pipelines are evaluated against the same annotations. All required full-track runs completed with matching audio, executable, model and output provenance checks.

Diarization error rate (DER) sums missed, extra and confused speaker-seconds and divides by reference speaker-seconds. Lower is better. One optimal speaker mapping spans each sample and selection category. Pooling sums components and denominators; it does not average the sample percentages. Reviewed silence counts toward false alarms, and uncertain ranges are excluded.

| Primary random clips | Saved server | Community-1 | Nemotron `.low` |
| --- | ---: | ---: | ---: |
| C | 18.05% | 11.65% | 20.93% |
| D | 75.00% | 71.66% | 104.20% |
| E | 29.67% | 30.94% | 29.47% |
| F | 19.27% | 31.28% | 22.67% |
| G | 21.01% | 15.77% | 21.55% |
| I | 27.12% | 27.84% | 21.75% |
| B | 27.47% | 17.90% | 16.82% |
| J | 18.21% | 25.06% | 25.61% |
| Pooled, no boundary exclusion | 28.45% | 28.92% | 32.44% |
| Pooled, ±250 ms boundary exclusion | 24.87% | 26.28% | 30.52% |

Overlap is included in this table. The collar is a half-width around reference boundaries, not a confidence interval. Overlap-excluded variants are retained in the private evaluation; the annotations contain only 0.118 seconds of overlapping speech, so this set cannot establish reliable overlap handling.

| Pooled, no boundary exclusion | Missed speaker-s | Extra speaker-s | Confused speaker-s |
| --- | ---: | ---: | ---: |
| Saved Server | 130.06 | 55.14 | 39.89 |
| Community-1 | 133.49 | 59.89 | 35.38 |
| Nemotron .low | 139.02 | 90.75 | 26.87 |

The shared no-collar denominator is 791.103 reference speaker-seconds. Independent timeline partitioning and SciPy assignment checks reproduce all scoring views; source-timeline exports also reconcile. Original annotations remain frozen. The reviewer confirmed a duplicate identity in J, and a recorded correction merges Speaker 15 into Speaker 4.

D has unusually high extra-speech error against the reviewed silence. DER can exceed 100% because error speaker-time can exceed reference speaker-time. As a sensitivity check, excluding D produces Saved Server 22.06%, Community-1 23.05%, Nemotron .low 22.59%. D remains in the primary result.

| Targeted speaker coverage only | Reference labels | Saved server | Community-1 | Nemotron `.low` |
| --- | ---: | ---: | ---: | ---: |
| I | 3 | 20.97% | 20.53% | 16.55% |
| B | 8 | 35.48% | 32.40% | 27.48% |
| J | 16 | 46.60% | 50.01% | 54.16% |

The targeted table uses no collar and includes overlap. Its clips were selected using saved labels, which introduces selection bias. J contains 16 reviewed labels in this view. If these are distinct, consistent identities, an eight-output-label system has a minimum DER of 26.51% under the global one-to-one mapping used here. This is a conditional capacity bound, not a measured result or a verified count of people present.

These descriptive results come from short excerpts in selected local meeting samples and one reviewer. There is no independent second review or population-level uncertainty claim. Offline full-track predictions do not establish live label accuracy, latency, or identity stability. The earlier resource measurements below remain separate evidence for deployment decisions.

The five additional local meeting samples supplied 285.60 minutes of audio per model. Serial full-file receipt wall times, including setup, totaled 73.36 seconds for Community-1 and 1,363.32 seconds for Nemotron `.low` (18.58 times longer). All ten additional runs completed without warnings. These are cached process measurements on the same Mac, not live latency or server runtime comparisons.

## Model size, architecture, resources and setup

This deployment comparison applies to the exact Core ML conversions tested, using FluidAudio v0.17.4 on an M1 Max with 64 GiB memory and macOS 26.6.2. Architecture descriptions come from pinned model cards and inspected metadata; sizes and resource counters were measured locally.

| Factor | Community-1 | Nemotron `.low` |
| --- | --- | --- |
| Verified model payload | 21.60 MB (20.60 MiB) | 199.12 MB (189.90 MiB) |
| Models plus benchmark executable | 31.29 MB | 208.83 MB |
| Architecture | Powerset speech/speaker segmentation → WeSpeaker ResNet34 embeddings → PLDA/VBx clustering | Streaming Sortformer, 100M parameters, 31-layer RoPE Transformer |
| Parameter count | Not established from inspected sources | 100M, declared by the model card |
| Inspected weight storage | FP32 segmentation/FBank/PldaRho; FP16 embedding | FP16 monolithic model; FP32 silence embedding |
| Processing | Whole-file clustering | Persistent streaming state, 20 ms audio feeds |
| Speaker capacity | Configurable file-level clustering; no fixed eight-slot limit | Eight speaker slots |
| Compute configuration | Core ML `.all`; FBank CPU-only; host clustering | Core ML `.all`; host mel frontend and streaming state |

MB means decimal megabytes. Model payload excludes SDK/build downloads, HTTP overhead, application packaging and Core ML specialization caches. The executable-plus-model sum also excludes shared system frameworks and is not a finished application size. Nemotron's payload is 9.22 times larger; a smaller model file does not imply lower runtime memory.

Architecture sources: [Community-1 model card](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/README.md), [Community-1 conversion provenance](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/PROVENANCE.md), and [Nemotron model card](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/blob/25a90f97f254428d4b30374b76af9c74fdee8327/README.md). Other Nemotron presets, including `.offline` and W8A8 conversions, were not evaluated.

### Measured resources on the additional five local meeting samples

These ten serial full-file runs processed 285.60 minutes of identical audio per model. Ranges span different recordings, not repeated trials. Earlier full-file and paced measurements below remain separate datasets.

| Measurement | Community-1 | Nemotron `.low` |
| --- | ---: | ---: |
| Peak process RSS | 459.69–1,090.65 MB | 79.97–110.64 MB |
| Peak process physical footprint | 712.70–968.25 MB | 56.80–95.01 MB |
| Mean process CPU, percent of one core | 116.45–167.42% | 7.55–8.13% |
| Cached model load | 127.41–159.03 ms | 126.42–156.48 ms |
| Total process CPU time | 102.61 s | 105.20 s |
| Total receipt wall time, including setup | 73.36 s | 1,363.32 s |

CPU percentage uses user plus system CPU time divided by process wall time; 100% is one CPU core. The models consumed similar total process CPU time despite different mean percentages because Nemotron ran much longer. CPU accounting excludes accelerator work. RSS and physical footprint are separate, nonadditive counters; neither measures all memory in separate Core ML services or GPU/Neural Engine allocations. Actual per-device utilization, whole-system memory and energy use remain unmeasured. `.all` allows device selection and does not prove Neural Engine execution.

For the separate five-minute paced replay, Community-1 used 331.04 MB peak physical footprint and 3.25% mean CPU, versus Nemotron's 49.33 MB and 1.37%. First outputs arrived after 10.215 and 1.206 seconds respectively. Community-1's ten-second update schedule is an adapter choice. These outputs were not validated as correct stable speaker identities. Cached load timings do not establish first-install or cold-cache startup; earlier initial Nemotron loads took about 66–69 seconds.

### Setup and dependency effort

Both local pipelines share the same benchmark setup. The practical sequence is to build two release Swift executables, explicitly download the pinned compiled model bundles, then pass prepared 16 kHz mono audio and local model paths. The [build and run commands](README.md#build-and-fetch) are already available. No training or model conversion is required for these supplied bundles. These measurements describe the standalone benchmark; they do not validate the later app integration.

| Layer | What is required or observed |
| --- | --- |
| Build tools | macOS with Swift 6.2+ and Apple command-line build tools; tested with Swift 6.4. The inspected binaries are arm64 with minimum macOS 14 metadata. Intel, iOS and execution on macOS 14 were not validated. |
| Library | One direct pinned Swift package, FluidAudio v0.17.4. Its full Swift library and C/C++ helpers compile because it has no separate diarization product. |
| Optional Rust feature | `traits: []` disables native NeMo text processing on Swift 6.2+. It was not linked in these executables, but SwiftPM still downloaded the prebuilt artifact during resolution. The build dependency footprint is therefore larger than the diarization runtime. |
| Preparation tools | The downloader and receipt harness use Python's standard library, invoked through `uv`. FFmpeg is used to prepare source audio. These are workflow tools, not dependencies of inference on an already prepared WAV. |
| Inference runtime | Native Swift, Core ML and Apple system frameworks. No Python interpreter, PyTorch or CUDA runtime is needed by the tested local executables. Once models are present, execution uses local files and does not fetch them. |
| Development storage | The inspected build and development caches occupied about 1.06 GB and 1.17 GB respectively. These are separate from the model payload and are not files to ship. |
| Known setup friction | An incremental Swift build stall required recovery in the isolated checkout. No clean-install duration or minimum-OS matrix was measured. |

The trait behavior is documented in the [pinned Swift 6.2 manifest](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Package%40swift-6.2.swift). This is a dependency audit of the tested pin, not a claim about every future FluidAudio release.

### Integration implications

Community-1 is the simpler fit for an after-meeting job: load the models, process the file and retain file-wide speaker labels. Live use needs additional cross-window identity matching and revision handling; the benchmark's rolling adapter does not implement those features. Nemotron exposes native persistent streaming and uses less measured process memory, but the tested eight-slot configuration cannot represent 10–20 distinct participants with one stable label each. Its raw probability threshold of 0.5 also has no smoothing in this harness. These are engineering assessments based on the interfaces and tested behavior, not measured implementation-time estimates.

The saved server baseline has no historical diarizer version, hardware, memory, startup or model-size receipt. Current worker code uses Community-1 through Python/WhisperX/PyTorch, FFmpeg and a CUDA-default RunPod container; its Python dependencies include WhisperX, OpenCC, RunPod and Requests. It requires configured access to gated upstream models and includes recognition and alignment as well as diarization. That is a broader deployment stack than the local executables. Current source and Dockerfile size comments cannot establish historical runtime, exact download bytes or a fair server-versus-local diarizer speed comparison.

## Full recordings

This initial runtime dataset uses different sample letters from the human-reviewed follow-up above.

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

Community-1 is the stronger performance candidate for after-meeting processing in these runs. Nemotron is the native streaming candidate. The human-reviewed comparison above adds an accuracy assessment to these runtime observations.

Existing meeting labels are unverified annotations. They contain 2, 3, 6, or 11 label IDs, not necessarily that many people. One reference has extensive overlapping labels and is unsuitable as ground truth without review. Microphone/system-track mixing and approximate alignment can introduce overlap or echo. These historical saved-label comparisons measure disagreement, not DER against reviewed audio.

The standalone package pins FluidAudio and disables its Rust text-processing trait. Runtime checks report no linked native Rust normalizer, but SwiftPM still downloaded the optional artifact during resolution. FluidAudio also compiles C/C++ helpers and its full Swift library. An incremental Swift Build stall was observed and recovered in the isolated checkout; supported macOS/toolchain matrix validation remains necessary before adopting this dependency in the app. Intel, battery use, sustained thermal behavior, and combined live Apple Speech plus diarization quality are untested.

Audio, input manifests, reference intervals, raw outputs, and binary-specific receipts remain outside Git. Only these anonymous aggregates are included here.

## Historical exploratory agreement with saved Rust annotations

This earlier dataset uses different sample letters from the selected-track follow-up below. Its results are retained as historical observations. The first exploratory comparison uses sample A, whose saved extraction and current audio durations differ by about 10 ms per track. The historical provider receipt is absent: current settings point to RunPod and the artifacts match its extraction protocol, but this does not independently prove which host processed that meeting. These are existing extraction annotations, not a verified RunPod accuracy benchmark.

| Scoring region | Community-1 disagreement | Nemotron disagreement |
| --- | ---: | ---: |
| Annotated speech, overlap included, no collar | 18.08% | 23.11% |
| Annotated speech, overlap excluded, no collar | 16.32% | 22.03% |
| Annotated speech, overlap included, ±250 ms collar | 17.45% | 23.41% |
| Annotated speech, overlap excluded, ±250 ms collar | 16.08% | 22.44% |

Lower means closer agreement with these saved annotations. The denominator is reference speaker-seconds after exclusions, not total recording time. A maximum-duration one-to-one assignment removes arbitrary label-name differences. Six existing track-scoped labels remain distinct; person assignments were not used to merge labels. Unannotated gaps are excluded rather than assumed silent. The uncollared overlap-inclusive region covers 2,752.01 seconds of audio and 2,815.90 reference speaker-seconds. Most disagreement is speech coverage: Community-1 has 399.79 missed and 109.29 confused speaker-seconds; Nemotron has 479.94 missed, 59.22 extra, and 111.71 confused speaker-seconds. Transcript segments may include pauses, so these are not confirmed model errors.

Community-1 is closer on this sample, but this single provisional reference cannot establish an accuracy ranking. Private reports identify disagreement intervals for listening; no listening adjudication had been completed at that stage. At that stage, other references needed timing or overlap review before their scores could support a comparison. The user-selected follow-up below supplies a new reference set for further review.

Read-only decoding checks found that both current FFmpeg Opus decoders reproduce the prepared duration for the two mismatched samples, and packet timestamps have no gaps. This ruled out a simple current decoder-choice or packet-gap explanation. The later selected-track audit below resolves its duration holds by reproducing worker end-only trimming. No offset or time stretching was fitted to improve agreement.

## User-selected single-track follow-up

Both models completed four additional full-track runs each, totaling 173.59 minutes of identical input per model. Three inputs used system audio and one used a room microphone; tracks were not mixed. Exact source mappings, per-meeting measurements, and predictions remain in ignored `tmp/`.

Community-1 used 52.66 seconds total end-to-end wall time; Nemotron `.low` used 790.83 seconds. Process peak RSS ranged from 530.91–690.77 MB and 84.07–96.45 MB respectively. These use the final executable hashes above, warmed model caches, and serial runs on the same Mac. They are observations, not isolated hardware benchmarks.

All four saved references are now eligible. Reproducing the worker’s preexisting end-only silence trim matches all four saved durations at their two-decimal precision: A loses a 10.1027-second tail and B a 1.3799-second tail; C/D need no trim. No offset, stretching, or fitting to model agreement was applied. Source/prepared-audio, saved reference, and prediction linkage passed hash checks. The missing historical upload hash and worker revision still limit retrospective provenance.

| Selected sample | Community-1 disagreement | Nemotron `.low` disagreement |
| --- | ---: | ---: |
| A | 17.03% | 26.23% |
| B | 40.87% | 41.58% |
| C | 16.29% | 22.25% |
| D | 19.70% | 39.34% |
| Pooled, no boundary exclusion | 24.93% | 32.22% |
| Pooled, ±250 ms boundary exclusion | 25.26% | 32.37% |

The no-collar denominator is 7,861.863 reference speaker-seconds. Pooling sums component durations after fitting a separate optimal label mapping per recording. These four references have no cross-label overlap, so including or excluding reference overlap produces identical scores; that does not establish absence of overlapping voices in the audio. Only A merges person-linked labels, when existing segment assignments, embedding assignments, and local profiles consistently identify the same person. Raw-label alternatives remain in the private audit.

These are transcript-segment speaker assignments, not verified diarization turns. Unannotated gaps remain unknown; extra speech measures additional simultaneous labels inside annotated regions and excludes predictions in unknown gaps. The earlier two-sample totals of 17.48% / 28.24% are superseded. Private `reference-audit.json` controls these derived results; original preparation/comparison artifacts retain their historical eligibility flags for provenance.

The scores establish agreement with saved annotations, not superiority over the server. Forty independently sampled 20-second clips and twelve separately selected diagnostic clips are ready for blind annotation. Those templates were unreviewed at that stage. The [evaluation procedure](EVALUATION.md) and scoring tools allow the server itself to make errors against independently reviewed speech, silence, and speaker labels. The later human-reviewed results appear above; live-label quality remains unmeasured.

## Selected-track resource audit

The preceding resource table describes the earlier full-recording dataset. Audited OS process counters for the selected-track follow-up are:

| Measurement | Community-1 | Nemotron `.low` |
| --- | ---: | ---: |
| Peak RSS | 530.91–690.77 MB | 84.20–96.60 MB |
| Peak physical footprint | 734.53–827.21 MB | 57.20–64.64 MB |
| Mean CPU, per-run range, percent of one core | 113.80–128.96% | 6.37–8.37% |
| Cached model load | 144–162 ms | 150–188 ms |

OS peak RSS can include activity after the executable’s summary counter quoted above. Mean CPU is user-plus-system CPU time divided by process wall time; it excludes accelerator work. OS process wall totals are 52.55 and 790.56 seconds; receipt totals of 52.66 and 790.83 seconds also include runner supervision. RSS and physical footprint are distinct counters, not additive or whole-system memory estimates.

Earlier one-minute paced runs used 323.18–323.73 MB physical footprint and 3.14–3.30% mean CPU for Community-1, versus 49.89–53.79 MB and 1.71–1.82% for Nemotron. These are short observations on the same host, not sustained energy or thermal measurements. Existing cached process starts do not measure first install, application launch, or controlled cold-cache startup. After approval service recovery, three fresh-process starts per model completed on the same ten-second excerpt. Model load ranged from 118.0–158.9 ms for Community-1 and 120.5–129.8 ms for Nemotron. Existing caches were retained. Community-1 detected no speech in this excerpt and skipped embedding/clustering, so its complete-process time is not a speech-processing comparison. The earlier failed sandbox receipt remains excluded. Both five-minute paced runs and a separate set of speech-excerpt startup repetitions subsequently completed, as reported below.

## Completed five-minute replay and startup repetitions

Both pipelines completed serial paced replays of the same 300-second selected-track excerpt, with matching input hashes and validated durations. This extends the earlier one-minute checks. Receipt artifacts passed hash verification. Loading and audio preparation occurred before the replay clock.

| Measurement | Community-1 window adapter | Nemotron `.low` |
| --- | ---: | ---: |
| Replay wall time, excluding setup | 300.327 s | 300.068 s |
| Complete receipt wall time, including setup | 300.604 s | 300.290 s |
| First output after replay start | 10.215 s | 1.206 s |
| Additional output delay, p95 | 349.51 ms | 81.74 ms |
| Worst simulated backlog | 353.09 ms | 145.91 ms |
| OS process peak RSS | 225.17 MB | 70.55 MB |
| OS process peak physical footprint | 331.04 MB | 49.33 MB |
| Mean CPU, percent of one core | 3.25% | 1.37% |

Community-1 produced 30 window updates without persistent speaker identities; Nemotron produced 417 probability chunks. First output is not a verified correct or stable label. Additional delay starts at scheduled input/window arrival and excludes the required buffer. Five minutes establishes bounded replay completion on this excerpt, not hour-long thermal behavior, energy cost, total-system memory, or speaker accuracy.

A further three fresh-process starts per model used the same ten-second excerpt with saved speech coverage. Community-1 completed segmentation, embedding and clustering in each run; both models emitted speech intervals. These runs retained existing caches and model files.

| Speech-excerpt measurement, three-run range | Community-1 | Nemotron `.low` |
| --- | ---: | ---: |
| Model load | 133.6–152.9 ms | 131.0–137.8 ms |
| Complete receipt wall time for 10 s of audio | 0.449–0.511 s | 1.044–1.056 s |
| OS process peak RSS | 116.03–116.49 MB | 62.06–63.06 MB |
| OS process peak physical footprint | 134.04–134.84 MB | 47.74–48.68 MB |

These are cached process starts and accelerated saved-file processing, not paced label latency or first-install startup. Complete receipt time includes launch, loading, audio preparation, inference and runner supervision. The initial three-run sample without Community-1 speech remains a separate valid load observation; it is not pooled with these speech-processing measurements. Download, cold device-cache specialization, application launch readiness, and actual per-operation CPU/GPU/ANE allocation remain unmeasured.

## Architecture and deployment audit

| Evidence | Community-1 | Nemotron `.low` |
| --- | --- | --- |
| Verified selected payload | 21,599,417 bytes (20.60 MiB) | 199,124,357 bytes (189.90 MiB) |
| Source-declared architecture | Powerset segmentation, WeSpeaker ResNet34 embeddings, PLDA/VBx clustering | Streaming Sortformer; 100M parameters and 31-layer RoPE Transformer |
| Inspected precision | FP32 segmentation/FBank/PldaRho, FP16 embedding storage | FP16 monolithic model, FP32 silence embedding |
| Inspected executable | arm64, minimum macOS 14.0 | arm64, minimum macOS 14.0 |
| Compute configuration | Core ML `.all`, FBank `.cpuOnly`, host clustering | Core ML `.all`, host mel frontend and streaming state |
| Actual CPU/GPU/ANE allocation | Host CPU work known; accelerator allocation unmeasured | Host CPU work known; accelerator allocation unmeasured |

All 26 selected model asset files match their manifest sizes and hashes. Nemotron’s payload is 9.22 times larger. Payload is verified object content, not measured network traffic, application size, or specialization-cache storage. Models are supplied as compiled `.mlmodelc` bundles; device-specific first-use preparation may still occur. Community-1 parameter count was not established from the inspected sources. The [pinned Community-1 card](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/README.md) and [pinned Nemotron card](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/blob/25a90f97f254428d4b30374b76af9c74fdee8327/README.md) support the architecture declarations; those declarations are distinct from local measurements.

The tested host is an M1 Max with 10 CPU cores, 64 GiB RAM, and macOS 26.6.2. Minimum OS metadata is not validation on macOS 14. Intel and iOS remain untested. Core ML `.all` permits available compute units; it does not establish ANE execution. The selected toolchain lacks `xctrace`, so no device trace is available.

Saved server outputs identify the ASR model but contain no historical diarizer revision, worker image digest, hardware, model-load time, download, or memory receipt. Current worker source uses the Community-1 family with CUDA by default, inside an ASR/alignment/diarization pipeline. Those source declarations cannot establish historical GPU use or justify cloud-versus-local runtime and memory rankings. Image model-size comments are estimates, not verified download payloads. The human-reviewed results above evaluate these saved outputs without attributing unrecorded runtime properties to them.
