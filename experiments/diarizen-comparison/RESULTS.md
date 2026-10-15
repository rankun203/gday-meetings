---
title: DiariZen Large-s80-v2 comparison
date: 2026-10-14
status: measured
scope: experiment-results
---

# Findings

One complete matched-input run per engine finished successfully. On this Mac, DiariZen CPU inference took **1,665.63 seconds**, versus **14.12 seconds** for Community-1 Core ML: about **118 times longer**. Peak process RSS was **5.00 GB** versus **0.584 GB**. These compare the available local implementations, including their different compute configurations; they do not isolate model architecture efficiency.

The outputs disagree substantially. DiariZen found more track-scoped speakers and retained overlapping turns, but detected less microphone speech and more system speech. No reference speaker timeline is available, so these results establish neither an accuracy winner nor a reason to replace Community-1. The private listening review shows both timelines and their projected text against the same audio.

The source code is MIT-licensed; the official weights are CC BY-NC 4.0. This separates research feasibility from product-distribution suitability. The candidate requires a pruned WavLM/Conformer segmentation checkpoint, WeSpeaker embedding checkpoint, and PLDA data, rather than one segmentation file alone.

# References

- [Official model card](https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md-v2): the pruned WavLM encoder has 63.3 million parameters, and the model supports up to four overlapping speakers. The model card reports no-collar DER on public benchmarks; these are not measurements against this app's Community-1 runtime.
- [Official repository](https://github.com/BUTSpeechFIT/DiariZen): inference uses segmentation, embeddings, clustering, and RTTM output. Code and model license differ. The setup and device choice were inspected at commit `844f5555b0a98acd0931511fc641a8c5b8ba92c7`.
- [Structured-pruning paper](https://arxiv.org/abs/2506.18623): background for the compact self-supervised encoder family. Its reported results cannot replace a matched-input local evaluation.
- [WeSpeaker dependency](https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM): the separate embedding checkpoint used by the official inference pipeline.

# Experiment setup

| Component | Pinned version or status |
| --- | --- |
| DiariZen code | `844f5555b0a98acd0931511fc641a8c5b8ba92c7` |
| Candidate model | `027b3e221b9d81dce2be794084f1dbd3ba2da403` |
| WeSpeaker model | `837717ddb9ff5507820346191109dc79c958d614` |
| Python | 3.10.22 |
| PyTorch / torchaudio | 2.1.1 / 2.1.1 |
| NumPy | 1.26.4 |
| Dependencies | `requirements-macos.lock`, bundled upstream pyannote fork |
| Candidate execution | CPU, four intra-op threads, one inter-op thread, batch size 4 |
| Host | MacBookPro18,4, Apple M1 Max, 10 CPU cores; macOS 26.6.2 arm64 |
| Host memory | 64 GiB installed RAM |
| Baseline | Community-1 revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`; Core ML FBank uses CPU, other models allow CPU/GPU/ANE |
| Audio | Each captured source processed separately, identical 16 kHz mono PCM16 WAV |
| Ground truth | No manually labeled reference currently available |

The two source tracks each contain 1,413.806 seconds; the real-time-factor denominator is their summed 2,827.612 seconds. Both engines receive identical WAV bytes and process silence without skipping. One full run per engine is measured sequentially with other builds and inference idle. Existing model caches are retained, and disk caches are not flushed.

Measurements cover diarization only. They exclude transcription, transcript projection, additional People Library voice-example extraction, and app publication. Required Community speaker-clustering embeddings remain enabled. The complete app reprocessing run is a separate operation.

Downloads and environment installation are excluded. Python imports are included in process wall time, but excluded from model initialization and inference timing. Model initialization is reported separately from per-track inference. Process-level timing includes initialization. A fresh subprocess measures peak resident memory; this does not measure GPU/ANE memory or total system memory pressure.

# Smoke validation

Both setup runs used the same 30-second system-audio excerpt. Batch size was the only model configuration override; clustering and segmentation thresholds were unchanged. Both produced exactly the same 11 acoustic turns. These runs overlapped app compilation and are compatibility checks, not controlled speed measurements.

| CPU setting | Model load | Inference | Process wall | CPU time | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Official batch 32 | 0.63 s | 21.97 s | 28.80 s | 72.41 s | 7.86 GB |
| Evaluation batch 4 | 0.44 s | 11.58 s | 16.65 s | 46.20 s | 4.46 GB |

Batch 4 is the evaluation default to bound memory. The short smoke test underestimated full-track inference time. Long-recording embedding extraction adds substantial work, so smoke timing is not used to predict the completed benchmark. Each full track is processed once; no repeated-run variance estimate is available.

# Metrics and comparison

Wall time is elapsed process or stage time. CPU time is user plus system CPU seconds and can exceed wall time when several cores run. Real-time factor is inference wall time divided by processed audio duration; smaller is faster. Peak RSS is the operating system's maximum resident set size, converted to bytes for each platform.

Acoustic coverage is the union of intervals with detected speech. Overlap duration is time with simultaneous distinct speakers. Speaker and turn counts describe behavior, not correctness. Projection coverage is the fraction of timed source text assigned by the same app projector; it must also report unresolved/coarse spans. More assigned text alone does not prove better diarization. Concurrent candidate speakers remain visible in the listening review; the projector conservatively leaves ambiguous timed text unresolved. Lower assignment coverage can therefore reflect retained overlap evidence rather than weaker speech detection.

Diarization error rate requires reference speaker timelines. Without reference labels, do not report DER or a quality winner. Review representative disagreement windows blindly when feasible, then label a small reference sample before making an accuracy claim.

| Measurement | Community-1 | DiariZen Large-s80-v2 |
| --- | --- | --- |
| Raw turns / track-scoped speakers | 379 / 9 | 686 / 16 |
| Overlap, summed across tracks | 0.00 s | 34.30 s |
| Assigned timed spans / total | 4,408 / 5,031 (87.62%) | 4,435 / 5,031 (88.15%) |
| Unresolved timed spans | 623 | 596 |
| Projected rows / unresolved rows | 680 / 408 | 872 / 488 |
| Inference wall | 14.120 s | 1,665.629 s |
| Process wall / CPU seconds | 15.572 s / 16.851 s | 1,672.606 s / 5,937.913 s |
| Model acquisition or initialization | 1.274 s | 0.478 s |
| Real-time factor | 0.004994 | 0.589058 |
| Peak process RSS | 0.584 GB | 5.001 GB |
| DER | Not measured: no reference | Not measured: no reference |

Both outputs were projected through the same pre-display-continuation release binary against one immutable 94-row transcript with 5,031 timed spans. No engine reran transcription. The candidate assigned 27 additional spans, a 0.54 percentage-point difference; this measures coverage only. Row counts reflect that frozen grouping behavior, not the later reading-passage presentation. Canonical span assignment remains separate from display continuation. The earlier app rerun assigned 4,460 spans (88.65%); that used a separate acoustic run and preparation, so it is not the matched benchmark baseline. The exact cause of the difference was not isolated; no deterministic equivalence is claimed.

Raw acoustic measurements separate engine behavior from transcript projection:

| Source / engine | Speakers | Turns | Speech union | Overlap |
| --- | ---: | ---: | ---: | ---: |
| Microphone / Community-1 | 2 | 117 | 238.32 s | 0.00 s |
| Microphone / DiariZen | 3 | 184 | 160.50 s | 4.98 s |
| System / Community-1 | 7 | 262 | 934.33 s | 0.00 s |
| System / DiariZen | 13 | 502 | 1,001.58 s | 29.32 s |

DiariZen per-track inference was 805.92 seconds for microphone and 859.71 seconds for system. Speaker counts are scoped to each source; summing them does not estimate unique people in the conversation. No clustering thresholds were changed to fit this recording. The official pipeline ran on CPU with batch size 4; it does not automatically select Metal/MPS or Core ML.

The generated private `review.html` includes 12 disagreement windows, local audio, acoustic speaker lanes, and both projected transcripts. Script syntax and generated structure passed checks. Automated browser interaction was unavailable because the browser tool rejected local file access; audio playback and visual layout therefore remain for user review.

# Limitations

One private recording is insufficient for a general replacement decision. CPU Python versus Core ML also mixes model and runtime effects. Archived app results are excluded from the matched comparison. Core ML permits accelerators, while DiariZen uses four CPU threads; actual Core ML operation placement, accelerator memory, energy, and total system memory pressure were not measured. No paid infrastructure, private uploads, or application replacement is part of this experiment.

The bundled pyannote fork imported the deprecated `speechbrain.pretrained` namespace. A recorded one-line patch uses the [supported classifier import](https://speechbrain.readthedocs.io/en/latest/API/speechbrain.inference.classifiers.html). It changes import compatibility only, not the selected WeSpeaker computation. Remove the patch when upstream adopts the supported namespace.
