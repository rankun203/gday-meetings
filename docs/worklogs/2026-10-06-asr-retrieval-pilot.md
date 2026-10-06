---
title: Transcription source and controlled retrieval scenarios
date: 2026-10-06
status: complete
scope: audio-retrieval-experiment
---

# Problem

The retrieval comparison used one existing transcript source. It did not isolate transcription errors, live revisions, or controlled acoustic and semantic failures.

# Implemented solution

Added reproducible runners under `experiments/audio-retrieval/asr/`: deterministic synthetic meetings, local Apple SpeechTranscriber file replay, pinned WhisperX large-v2 recognition and alignment, fixed-window projection, and retrieval scoring using the existing encoders. All generated audio and outputs remain in ignored storage. App code and the active library are unchanged.

The pilot has six template families in English and Chinese, 24 clean/noisy recordings, 144 window instances, and 72 queries. Forty-eight queries have specified positive windows; 24 request a supplier that the meeting has not selected. The latter are retained for future answer/abstention evaluation and excluded from evidence-hit denominators. Each retrieval gallery contains 36 windows in one spoken language to avoid treating equivalent bilingual scripts as false negatives. Paired acoustic variants are not independent scenarios.

# Reasoning

Whole synthetic recordings preserve context for ASR. Common windows isolate transcript input differences. Apple uses the app's progressive preset and requested PCM format; accelerated replay evaluates final text, while four real-time replays retain progressive events. WhisperX uses the pinned large-v2 checkpoint on CPU/int8, so its timings do not represent the RunPod GPU worker. The transcription task is explicit to avoid WhisperX's language-switch path passing a numeric task token to its tokenizer.

# Technical debt

The pinned WhisperX dependency stack warns that its optional TorchCodec file decoder cannot load against the installed FFmpeg libraries. The runner supplies already decoded arrays through WhisperX's FFmpeg loader, so that optional path is not exercised. Retaining the pinned stack preserves this comparison's configuration; a separate dependency update and decoder compatibility check are needed before using TorchCodec file input. No warnings are suppressed by the experiment.

The generated scripts are intended speech, not audio-verified gold. Their mismatch rates include number-format differences and cannot establish ASR word-error rates on natural meetings. Independent listening and held-out real recordings remain required before model selection.

# Progress and validation

- Validated nonempty, nonsilent synthesis. Sandboxed speech synthesis initially produced empty utterances; those fixtures are excluded.
- Compiled the standalone Apple harness with optimization. Corrected its PCM format to the format requested by SpeechAnalyzer after an initial framework precondition failure. Embedded a stable bundle identifier.
- Investigated the Chinese alignment warning: its pinned pretrained config includes the deprecated `gradient_checkpointing` initialization option. The experiment performs inference only; the supported training API is `gradient_checkpointing_enable()`, which is not needed here. Retain the dependency warning for this pinned run; update the upstream alignment config/model revision and revalidate timestamps before removing it. No runtime monkeypatch was introduced.
- Completed both recognizers on all 24 corrected recordings (803.04 seconds), plus four Apple real-time replays. Fixed an accidental contradictory budget in the final template; regenerated/retranscribed its four recordings and recomputed the retrieval matrices. Earlier artifacts remain excluded in ignored storage.
- Matched the worker's OpenCC `tw2sp` conversion for simplified-Chinese output before projecting WhisperX words. Recomputed the affected embeddings; raw recognition remains available.
- Scored 17 configurations. Jina first-result evidence hits: intended script 100%; Apple clean/noisy 97.9%/93.8%; WhisperX clean/noisy 100%/87.5%; direct audio clean/noisy 83.3%/66.7%. Granite 311M reached 70.8% on scripts, 62.5%/62.5% on Apple text, and 62.5%/56.2% on WhisperX text. Its 14 script-control misses all concern corrected decisions, with an introduction or outdated proposal first.
- Audio recovers three of six first-result misses for noisy WhisperX text, while text succeeds on 13 audio misses. This is complementary evidence, not a measured routing strategy. The corrected noisy Apple condition has no audio-only first-result hits.
- Integrated setup, pilot matrix, mismatch diagnostics, ablations, runtime limits and findings into the existing `RESULTS.md`. The larger held-out natural-meeting and library-scale experiments remain planned; the completed work is the controlled pilot.
- Validation: ten existing comparison tests and seven ASR tests passed; new Python sources pass Ruff checks. The formatted standalone Swift harness compiled with optimization without compiler warnings. All final model inputs and ASR audio hashes validate. ASR dependency warnings described above remain; no full-app build was needed because app code did not change.
