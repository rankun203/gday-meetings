---
title: Local transcription provider comparison
date: 2026-10-23
status: ready-for-review
scope: offline-transcription-experiment
---

## Problem

Provider descriptions and published benchmarks do not establish transcription quality or resource use on the user's recordings and Mac.

## User Intention

Compare Nemotron 3.5 ASR through the intended FluidInference Core ML conversion, the app's Apple transcription path and an embeddable local Whisper solution. Develop against a short authorized recording, then include a longer recording and an English recording for human judgment. Prepare a private listening-and-rating page to help choose among future app providers. Preserve all source libraries and exclude private meeting information from tracked files.

## Implemented solution

An isolated experiment under `experiments/local-transcription-comparison/` prepares independent audio copies, shared mono 16 kHz PCM, serial native-provider runs and a local HTML comparison page. Pinned, optimized native adapters now run Apple SpeechAnalyzer, FluidAudio Nemotron Core ML and WhisperKit. All three providers completed all six recording/track combinations in the primary serial pass. Generated audio, transcripts, model files, configurations, receipts and judgments remain ignored.

The generated page has a recording/track selector, one shared audio player, three initially blinded transcript columns, timestamp playback, five quality ratings, notes, an optional checked reference, provider/resource reveal and JSON export. Ratings are tied to exact result hashes; recording notes and checked references are tied to the audio. Revealing providers preserves playback. No automatic error-rate claim is made without human ground truth.

## Reasoning

Use the runtime intended for integration to measure relevant local behavior. Hold audio preparation constant and retain source-track provenance. Separate setup/download, model load, file decode, inference and invocation latency. Report process CPU/RSS accounting explicitly: Apple's system-service work may be outside the client process, so client memory alone cannot establish a fair total-memory ranking. Compare quality through listening before interpreting resource tradeoffs.

## Technical debt

No production integration or storage change. The initial Nemotron adapter returned whole-recording text. Its public SDK token-timing API now supports conservative review-page grouping: the English diagnostic passed, while the short diagnostic exceeded real audio bounds by 314 ms and retained whole-recording text. A later long-microphone diagnostic produced 24 validated groups; the long system track retains its original whole-recording result. Latest transcript text remains byte-identical to the primary matrix. Timestamp quality still needs listening validation. Process-only resource accounting excludes system-service and accelerator allocations, so it cannot support a total-memory or battery ranking. WhisperKit can fall back to a tokenizer download if local assets change after preflight; immutable staged assets and hash manifests limit this experiment risk, while production integration should enforce a stronger offline-loading contract. Human quality rankings and integration decisions remain pending judgment.

## Notes

The exact Core ML repository is accessible through the existing local Hugging Face setup despite its model-card access-request notice. The HF CLI skill was read; the executable was unavailable, so metadata checks used the documented Python Hub API through an ephemeral `uv` environment without exposing credentials. Model access does not establish inference correctness.

The review page passed JavaScript syntax and synthetic embedding checks. Browser policy rejected local file access and prohibited alternate-protocol/surface workarounds; rendered layout and browser interaction checks remain unverified. Benchmark runs are serialized after the separate speaker-attribution experiment to reduce contention. Claude Code Opus 5.5 review of the preceding experiment was blocked by a usage-limit response; no completed external review is claimed for this work.

Independent read-only review found three material issues, all fixed and re-reviewed: per-invocation audio/executable hash verification, disclosure of nonidentical timing scopes in the page, and cleanup after Nemotron input failures. Apple asset installation is a separate explicit setup command that preserves existing locale reservations. Initial Apple readiness failure is retained with its receipt; later successful runs do not overwrite it. Whisper completed its first Neural Engine model load naturally after about 231 seconds; later fresh-process loading took about two seconds. No alternate compute backend was substituted.

The primary matrix includes 18 successful optimized native invocations. On system tracks, native totals were 1.74/4.40/18.17 seconds for the short recording, 22.95/55.02/233.39 seconds for the long recording, and 8.82/16.72/56.92 seconds for English (Apple/Nemotron/Whisper). Initial model loading and microphone-track results are reported separately in the experiment results. These measurements establish neither transcription accuracy nor total system memory use.

Validation: six Python regression tests passed; standalone Swift timing checks passed; strict app-config Swift formatting, release compilation and signature verification passed. The final diagnostic binary hash remained identical after formatting, with exact measured source and binary snapshots retained privately. Existing Command Line Tools linker search-path warnings remain. Human quality judgments and rendered browser checks are the remaining evaluation limits. No production provider, app bundle or source library was changed.

Final integrity checks verified all six source audio files, six original copies, six PCM fixtures and 65 model artifacts unchanged. The private page and aggregate report are ready for user evaluation.
