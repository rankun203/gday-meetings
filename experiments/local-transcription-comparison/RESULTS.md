---
title: Local transcription comparison results
date: 2026-10-23
status: measured
scope: offline-transcription-experiment
---

# Local transcription comparison results

## Findings

All three providers completed all six prepared tracks: 18 successful comparisons. Apple had the shortest measured total on every track. Nemotron was faster than Whisper on the system tracks; their order reversed on the longer microphone tracks. This is a pipeline-speed result on one Mac, not a transcription-quality ranking. Initial Core ML loading was much slower than subsequent fresh-process loading. The user completed qualitative listening review through written feedback rather than completing the page ratings. Apple remains the preferred default, with diarization improvements the next priority.

## References

- [NVIDIA Nemotron 3.5 ASR streaming model](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b): upstream multilingual streaming ASR model.
- [FluidInference Core ML conversion](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML): intended Apple Silicon runtime weights. The model card advertises different language vocabularies and chunk-size tiers and includes an access-request notice; repository metadata and compiled-weight access are available through the existing local setup.
- [WhisperKit / Argmax Swift runtime](https://github.com/argmaxinc/argmax-oss-swift): embeddable Swift implementation with local Core ML inference. This experiment selects the multilingual compressed large-v3-turbo model.
- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer): the supported recorded-file analysis API used by the app adapter. Apple assets are managed by the operating system rather than downloaded into the experiment model directory.

## Experiment setup

Independent snapshots preserve both original Opus tracks per authorized recording. Their durations are 128.73 seconds (short), 2,113.87 seconds (long) and 748.55 seconds (English), each with separate microphone and system tracks. Shared mono 16 kHz PCM totals about 191 MB across all six tracks. Source audio hashes stayed unchanged during capture. Each engine receives these same prepared tracks.

The native executable is built with Swift release optimization on an Apple M1 Max with 64 GiB memory, running macOS 26.6.2 (25G83). FluidAudio is pinned to `c79c4106b954f81205113c3343e5a7e59a1089b5`; Argmax Swift is pinned to `9f99b5cb6a907730543823ad271b82532782a899`. Nemotron Core ML weights are pinned to `1a41b75758b0337ff67db7d5408280aaaf23074e`. Whisper weights use `openai_whisper-large-v3-v20240930_626MB` at `0f63a7800b00dd0226abd051b906c246e1907482`.

Nemotron retains the SDK's CPU/Neural Engine default with no `FLUIDAUDIO_*` environment overrides. It uses the 2,240 ms streaming tier, the full multilingual vocabulary for Chinese and the Latin vocabulary for English. It keeps stream state across bounded 60-second file reads and decodes the accumulated transcript at completion. This measures recorded-file throughput, not live first-token latency. Whisper uses one decoding worker, an explicit language and transcription rather than translation. Runtime defaults place the encoder and decoder on CPU/Neural Engine and the mel-spectrogram stage on CPU/GPU; decoder fallback settings remain the pinned package defaults. Apple requests final timed results through pull-based file analysis. None of these adapters performs speaker attribution.

Public experiment sources use generic fixture identifiers. Private inputs, manifests and generated transcripts remain ignored. Compare identical audio and retain runtime/configuration receipts. Asset downloads and shared conversion are setup costs, recorded separately from provider inference.

## Results

Native total measures adapter setup through output preparation. Process wall time additionally includes executable launch and termination, as recorded by the Python runner and `/usr/bin/time`. Transcription time is provider-specific: Nemotron includes decoding, Whisper reports decoding separately, and Apple includes deferred service work. Throughput is audio duration divided by native total; a value of 10× means ten seconds of audio processed per elapsed second. CPU time sums the client process's user and system CPU time and can exceed wall time through parallel work. Peak resident set size (RSS) is the process high-water memory reading, not system-wide model memory.

### Short development track

The same 128.73-second system track was processed serially. These are single invocations, not confidence intervals. Total is the native invocation duration; it includes model readiness/loading, transcription and cleanup. It excludes process launch and prepared-audio/model download setup.

| Provider | Initial model load | Later model load | Later transcription | Later native total | Later client peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Apple SpeechAnalyzer | Asset preflight stopped the initial run | 0.09 s | 1.65 s | 1.74 s | 22.0 MiB |
| Nemotron Core ML | 25.62 s | 0.36 s | 4.03 s | 4.40 s | 121.6 MiB |
| WhisperKit | 231.25 s | 2.02 s | 16.10 s | 18.17 s | 170.5 MiB |

Apple asset preparation was explicitly performed outside measurement for both languages. The official installation request completed in under a second per language; that is a readiness/setup measurement, not evidence of a complete model download over the network. Apple's load field covers readiness/module creation; any deferred service loading is included in transcription.

Whisper's initial load completed naturally after about four minutes; no process was killed and no compute fallback was substituted. A long-lived Neural Engine compiler service was active during loading. Its process age does not establish a hang or unrelated contention. Compilation-cache state is uncontrolled; repeat invocations must not be described as resident-model warm benchmarks.

The RSS column covers only the client process. Apple speech services and Core ML/accelerator allocations outside that process are excluded. These figures do not establish a total-memory ranking.

### Full evaluation

This matrix uses the original completed serial pass: short/system iteration 1 and all other tracks iteration 0. Subsequent timestamp diagnostics are separate; the page retains their exact result hashes and may display the later transcript for those cases. Provider order was fixed, not randomized. Each row is one observation; no statistical confidence interval is claimed.

#### System tracks

| Recording | Provider | Load (s) | Native total (s) | Process wall (s) | Throughput | Client CPU (s) | Client RSS (MiB) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Short | Apple | 0.09 | 1.74 | 1.77 | 74.1× | 0.16 | 22.0 |
| Short | Nemotron | 0.36 | 4.40 | 4.44 | 29.3× | 10.85 | 121.6 |
| Short | WhisperKit | 2.02 | 18.17 | 18.22 | 7.1× | 7.07 | 170.5 |
| Long | Apple | 0.12 | 22.95 | 22.99 | 92.1× | 1.93 | 21.6 |
| Long | Nemotron | 0.24 | 55.02 | 55.05 | 38.4× | 154.98 | 127.0 |
| Long | WhisperKit | 1.81 | 233.39 | 233.47 | 9.1× | 70.44 | 432.5 |
| English | Apple | 0.10 | 8.82 | 8.86 | 84.9× | 0.54 | 19.9 |
| English | Nemotron | 0.22 | 16.72 | 16.76 | 44.8× | 29.54 | 108.5 |
| English | WhisperKit | 1.76 | 56.92 | 56.94 | 13.2× | 13.44 | 279.0 |

#### Microphone tracks

| Recording | Provider | Load (s) | Native total (s) | Process wall (s) | Throughput | Client CPU (s) | Client RSS (MiB) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Short | Apple | 0.10 | 0.82 | 0.87 | 156.4× | 0.05 | 18.6 |
| Short | Nemotron | 0.22 | 3.54 | 3.60 | 36.3× | 8.50 | 119.6 |
| Short | WhisperKit | 1.83 | 8.61 | 8.68 | 15.0× | 2.90 | 166.7 |
| Long | Apple | 0.09 | 11.51 | 11.57 | 183.7× | 0.76 | 20.0 |
| Long | Nemotron | 0.22 | 210.69 | 210.73 | 10.0× | 390.47 | 123.2 |
| Long | WhisperKit | 1.81 | 163.18 | 163.25 | 13.0× | 45.45 | 429.1 |
| English | Apple | 0.10 | 5.48 | 5.50 | 136.6× | 0.31 | 20.2 |
| English | Nemotron | 24.60 | 75.28 | 75.34 | 9.9× | 69.66 | 614.4 |
| English | WhisperKit | 1.99 | 51.33 | 51.39 | 14.6× | 11.72 | 279.8 |

The first English microphone Nemotron run also loaded the Latin-vocabulary variant for the first time: 24.60 seconds of its 75.28-second total was model loading, and 50.67 seconds was transcription. The later English system run reused compilation caches. This is not a fully balanced cold/warm experiment.

On the long Chinese recording, Nemotron transcription itself took 210.45 seconds for microphone audio versus 54.77 seconds for system audio. Input content affects pipeline cost; long-track diagnostic counters were not captured in this original pass, so the specific cause is not established. Do not extrapolate cost from duration alone.

### User listening review

The user finished judging on October 23 and supplied written feedback as the final qualitative review. The page's incomplete ratings are not a completed numerical evaluation and must not be averaged or filled in retrospectively.

- Short recording: Apple was preferred, including its readable sentence segmentation. Sentence segmentation is not evidence of speaker diarization.
- Longer microphone excerpt: the user's annotations favored Whisper for a technical passage, judged Apple good and marked Nemotron errors. This is a passage-level observation, not a ranking of the entire recording.
- English recording: the user again judged Apple good.

The resulting product direction is to retain Apple as the preferred transcription option and focus on better diarization. Whisper showed useful strengths on some mixed-language technical speech. These observations do not establish general accuracy, a complete ordering across all tracks or measured WER/CER. No private meeting content is reproduced here.

### Review-page timing and quality

The private page includes all three recordings, both source tracks, locally playable audio, three initially unnamed result columns, five quality ratings, notes, optional checked-reference text and JSON export. Revealing providers shows model identifiers, timings, client resource readings and accounting scopes. Ratings are keyed to the exact result hash. No WER/CER is calculated, and no machine transcript is treated as human ground truth.

Apple and Whisper provide timed segments. The later Nemotron diagnostic adapter uses the SDK's real decoder-emission timestamps, grouping them at one-second gaps or 12-second spans only when ordering, audio bounds and exact UTF-8 transcript preservation pass. These are display groups, not validated word alignment. The short system track failed bounds validation: the last emission extended 314 ms beyond real audio, with no backward time jumps. Its full text is retained with a whole-recording fallback. The English system diagnostic passed and produced 95 groups, with zero end overrun or backward jumps. A later long-microphone diagnostic completed with 24 validated groups before cancellation reached the following run. The long system track retains its original whole-recording output. These later diagnostics do not replace the primary timing matrix; all 18 latest transcripts remain byte-identical to their primary results. No timestamps were sorted, interpolated or invented to force a pass.

### Validation

The optimized native executable ran all 18 primary cases successfully. Six Python regression tests cover the orchestration/page contract; standalone Swift checks cover Unicode byte preservation, grouping, final-frame bounds and explicit fallback. Independent read-only review findings were fixed and checked again. Rendered browser and interaction QA could not be completed because the browser tool denied local-file access and prohibited an alternate access workaround. The private page passed static JavaScript and synthetic-data checks. The release link retained existing Command Line Tools search-path warnings; no new deprecation warning was reported.


## Limitations

Three recordings can expose useful differences but cannot establish general transcription accuracy. Qualitative written judgments are complete; standardized ratings and human-corrected references were not completed. Resource measurements on a shared workstation must identify model loading, inference and system-service accounting limits. Upstream GPU benchmarks cannot establish Core ML performance on this Mac. Shared 16 kHz normalization makes engine inputs comparable but does not reproduce every original-format production path. Model loading is measured in fresh processes with uncontrolled operating-system compilation caches; repeated invocations are not a continuously resident, warmed provider. Timestamp accuracy and live streaming response latency are not established by these throughput runs.

Final integrity verification confirmed that six source audio files, six independent original copies, six PCM fixtures and 65 staged model artifacts remained unchanged. Exact measured native sources, binary hashes, invocation receipts and final experiment-source snapshots are retained in ignored private artifacts.
