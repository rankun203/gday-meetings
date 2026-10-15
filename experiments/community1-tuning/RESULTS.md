---
title: Community-1 configuration ablation results
date: 2026-10-15
status: measured
scope: experiment-results
---

# Findings

The denser segmentation hop improved conditional agreement with remote final labels on system audio, including on an identical comparison population. It also took 2.23 times as much inference time, raised peak process RSS from 0.838 GB to 1.157 GB, and assigned 136 fewer native timed spans. Microphone agreement was unchanged. This mixed result does not justify changing the production default.

On the fixed 2,110.399-second system comparison population, mapped agreement rose from 92.00% to 93.33%, equivalent to 28.096 fewer seconds of mapped disagreement. Both conditions retain their independently fitted global speaker mappings; neither mapping was recomputed on the common subset. Agreement with another automatic output does not establish accuracy. Overlap retention remains a separate unrun ablation.

# References

[FluidAudio configuration source](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift) defines `OfflineDiarizerConfig`, the 0.2 default segmentation step ratio, and exclusive postprocessing. The local pinned source is the implementation authority. A source comment describes a speed/DER tradeoff involving both hop and minimum embedding duration; it does not establish the effect of changing the hop alone here.

[Offline manager](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift) accepts configuration at initialization. [Reconstruction](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/Diarizer/Offline/Utils/OfflineReconstruction.swift) applies exclusive output as postprocessing. Exclusive output and embedding overlap exclusion are different settings; embedding overlap exclusion remains unchanged.

# Experiment setup

The model revision is `df2625ac79a7ac6b65ad868fee6d80f320da4232`; FluidAudio is pinned to `21493f8dac5a97e65742e6ff26f42f164c2fda0f`. All 21 cached model assets passed app-catalog size and digest verification. The isolated release executable uses cached dependencies without downloads. Synthetic configuration tests confirm that each profile changes exactly one field from the pinned default.

| Profile | Segmentation step ratio | Hop for ten-second window | Exclusive output |
| --- | ---: | ---: | --- |
| baseline | 0.2 | 2 s | Yes |
| dense | 0.1 | 1 s | Yes |
| overlap, deferred | 0.2 | 2 s | No |

The MacBookPro18,4 has an Apple M1 Max with 10 CPU cores and 64 GiB RAM, running macOS 26.6.2. Core ML allows all compute units except FBank, which uses CPU; actual accelerator placement was not measured. Each profile ran once, serially, in a fresh process per track. Baseline ran first, followed by dense. Existing caches were not flushed, and no competing builds or inference ran during measurement.

The native loader rejected the original Opus containers before inference. Each source was therefore decoded once with FFmpeg to 48 kHz float PCM WAV, preserving channels, before FluidAudio's native 16 kHz conversion. The intermediate format matches the app, but FFmpeg and the app's decoder are not assumed byte-identical. Both profiles received the same decoded bytes. Original and decoded hashes were verified again after inference. Decode preparation, including decoding, metadata inspection, and hashing, took 8.70 and 12.05 seconds and is excluded from measured model processes.

Each track contains 4,486.504 seconds; the real-time-factor denominator is their summed 8,973.009 seconds. The same isolated release projector received the immutable transcription artifact's 368 original rows and 14,820 timed spans. Both projected outputs preserve all 17,981 source UTF-16 units exactly once, and each displayed row reconstructs exactly from its source anchors. Earlier split transcript output was not used as input.

# Resource and coverage results

Inference wall time includes model preparation and clustering after audio loading. Process wall/CPU/RSS also include process startup, model loading, and native audio conversion. CPU seconds sum user and system time; maximum RSS is the largest per-track process peak, not the sum. Real-time factor divides summed inference wall time by summed source duration. Assigned spans measure projection coverage, not speaker correctness.

| Measurement | Baseline | Dense |
| --- | ---: | ---: |
| Inference wall, both tracks | 36.02 s | 80.36 s |
| Process wall, both tracks | 39.36 s | 82.25 s |
| Process CPU, both tracks | 54.87 s | 108.92 s |
| Maximum process RSS | 0.838 GB | 1.157 GB |
| Real-time factor | 0.004014 | 0.008955 |
| Assigned timed spans / 14,820 | 13,277 (89.59%) | 13,141 (88.67%) |
| Unresolved timed spans | 1,543 | 1,679 |
| Raw microphone / system speakers | 2 / 10 | 2 / 12 |
| Raw microphone / system turns | 362 / 572 | 356 / 559 |

# Conditional final-label agreement

The existing remote response contains final aligned word labels, not raw speaker turns. The comparison fits a maximum-duration one-to-one anonymous speaker mapping separately for each local condition and source. It excludes unresolved and simultaneous-label intervals. Missing timing and attribution coverage are reported separately; this is neither raw acoustic agreement nor reference DER.

| Source / condition | Local timed union | Local speaker-covered union | Shared single-speaker time with remote | Conditional mapped agreement |
| --- | ---: | ---: | ---: | ---: |
| Microphone / baseline | 699.00 s | 461.70 s | 443.132 s | 98.1703% |
| Microphone / dense | 699.00 s | 463.74 s | 443.004 s | 98.1698% |
| System / baseline | 3,019.20 s | 2,228.88 s | 2,153.126 s | 91.3364% |
| System / dense | 3,019.20 s | 2,203.08 s | 2,131.368 s | 93.2072% |

Remote timed/speaker-covered unions are 1,316.982 seconds for microphone and 3,381.338 seconds for system. Different transcription and alignment outputs affect these unions. A denser diarization hop cannot recover native transcript text or timing that is absent.

To remove the changing comparison denominator, retain only intervals where baseline, dense, and remote each have exactly one assigned speaker. Keep each previously fitted mapping fixed:

| Source | Identical comparison duration | Baseline disagreement | Dense disagreement | Baseline agreement | Dense agreement |
| --- | ---: | ---: | ---: | ---: | ---: |
| Microphone | 441.073 s | 8.108 s | 8.108 s | 98.1618% | 98.1618% |
| System | 2,110.399 s | 168.873 s | 140.777 s | 91.9981% | 93.3294% |

The system gain persists on identical support, but the full dense output has lower assigned-span coverage and greater resource cost. Keep the default unchanged while reviewing these tradeoffs.

# Validation and limitations

The release build and three synthetic tests passed, covering exact configuration differences, invalid profiles, normalized turn bounds/identity, identical-support agreement, and omitted/duplicate text anchors. The shared projector completed for both candidates. Private provenance includes executable hashes and unchanged input hashes. No model downloads, library writes, or production defaults changed.

The build emitted linker warnings for absent Command Line Tools developer library/framework search paths. Linking and executable checks passed; no deprecated API warning was identified. These warnings remain visible rather than describing the build as warning-free.

One recording and one run per condition do not establish general accuracy or runtime variance. Global speaker mappings are optimized against the same remote comparison output, not independently labeled truth. The overlap profile was not run, thresholds were not tuned, and no further inference is needed to report this ablation.
