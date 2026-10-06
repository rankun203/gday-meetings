---
title: Expanded meeting retrieval evaluation
date: 2026-10-06
status: completed-with-limits
scope: audio-retrieval-experiment
---

# Problem

The comparison still used 50 queries and 150 windows. A synthetic correction task had separated two previously tied encoders, motivating closer evaluation of competing proposals and changed decisions on recorded meetings.

# Implemented solution

Added reproducible corpus construction, encoder orchestration, reference-conditioned grading, transcript variants and aggregate scoring under `experiments/audio-retrieval/expanded/`, plus a pinned CLSP runner. The frozen gallery contains 1,500 historical windows and 177 reviewed-excerpt windows. All 102 queries search all 1,677 candidates across 49 meetings; queries target 27 meetings. Private recordings, query wording, source mappings and generated artifacts remain ignored.

Completed ten primary encoder processes and nine transcript-variant processes. Reran WhisperX on the 22 selected source excerpts. The main comparison contains 18 distinct methods and 4,699 graded query–passage pairs. A separate 243-pair first-result pool measures transcript sensitivity. Rewrote `RESULTS.md` as one account: findings, literature, setup, main matrix, paired failure analysis, transcript and fusion ablations, resources and limitations. Updated reproduction instructions. The repository's existing coherent-results rule remains applicable.

# Reasoning

Keep historical transcript labels, explicit human corrections and qualitative endorsement distinct. Freeze queries and competing windows before reading expanded rankings. Compare encoders on identical inputs, then change only the 177 new passages to isolate transcript sensitivity. Qwen was added to the transcript ablation after the initial text results, so model selection remains exploratory.

The original query-only judge overcredited a general rule without the requested changed detail. Superseded those grades with one reference-conditioned rubric. Structured short output keys prevent copied-ID errors; reuse requires identical input records, rubric and model. Full support remains an automated estimate, with observed grading inconsistencies disclosed.

# Results and validation

Jina and Qwen reach 69.6% labeled first hits; Granite 311M reaches 63.7%. Granite reaches 90% on the selected decision/status challenge versus Jina's 85%, so the synthetic failure pattern does not generalize to this set. Reviewed-span hits improve from 34.4% to 62.5% for Jina and from 18.8% to 46.9% for Granite after local transcript corrections. Fixed Jina audio + transcript fusion reaches 37.3% overall and does not improve reviewed-span first hits.

Ten retrieval tests, six expansion/support tests and eleven reference-review tests pass. The first review-test invocation omitted OpenCC; it passes with the documented dependency. Numerical checks cover twelve new Jina/Granite CPU–Metal comparisons, six CLSP probes, all 918 unchanged variant query vectors, and exact equality of Jina's 1,779 full/text-only vectors. Audio format, duration, finite samples, fingerprints and complete grading coverage pass. Four silent windows and 21 empty main-corpus passages remain candidates. Independent variant rescoring reproduces the saved metrics and rankings. Original user review files are unchanged.

GPU execution required leaving the sandbox because it reported Metal as unavailable. CPU recognition overlapped part of the primary run; CLSP also overlapped transcript-variant GPU runs. Resource timings are observational. The report records these conditions. No app code changed for this task, so no app release build was needed. Separate app edits in the shared workspace were left untouched.

# Technical debt

CLSP's frozen implementation requires Transformers 4.57.3 and Torch 2.8.0; it fails with the newer model-loading interface. It also emits legacy AMP decorator/autocast warnings. Current [PyTorch AMP](https://docs.pytorch.org/docs/stable/amp.html) uses `torch.amp` APIs with a device type. Retaining the older runtime preserves checkpoint parity, but creates a separate dependency environment. Replace it only after validating an upstream implementation against the saved vectors.

WhisperX's alignment checkpoint emits a deprecated gradient-checkpointing configuration warning; training is disabled. A future config/checkpoint migration must preserve recognition and alignment behavior; see the [Transformers model APIs](https://huggingface.co/docs/transformers/main_classes/model). Its optional TorchCodec decoder cannot load the installed FFmpeg libraries. The runner supplies predecoded arrays, so that decoder is unused; repair the compatible decoder/runtime combination before enabling that path. No dependency warnings were suppressed.

Partial reviewed references and historical labels remain evaluation limitations rather than complete gold transcripts. Source rendering emitted demux warnings; valid decoded outputs do not prove complete source streams. Independent listening, held-out queries and absent-answer cases remain necessary before treating this development benchmark as a production acceptance test.

# Commit preparation

Extended `.gitignore` to nested experiment artifact directories, private-named files, Ruff caches and local session output. Kept the historical review queue and focused rendering in separate directories in the reproduction commands; the queue builder now refuses existing output directories to preserve annotations. The complete source set passes 34 tests, including the historical synthetic ASR checks. Staging excludes unrelated app work, recordings, model downloads, transcripts and generated artifacts.
