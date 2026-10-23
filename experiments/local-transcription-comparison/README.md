---
title: Local transcription comparison
date: 2026-10-23
status: ready-for-review
scope: offline-transcription-experiment
---

# Local transcription comparison

Compare the proposed Nemotron Core ML provider, the app's Apple transcription implementation and an embeddable local Whisper runtime. Evaluate a short development recording, a longer recording and an English recording. Keep all private audio, transcripts, paths, model files, ratings and raw measurements under ignored `tmp/` storage.

## Intended evaluation

Each provider receives the same prepared audio track and declared language. Preserve microphone and system provenance; never silently mix tracks for only one engine. Record model revision, precision, runtime, chunking, decoding configuration, operating system and hardware. Measure model download/setup separately from load, transcription and output finalization. Report wall time, CPU time, process peak resident memory, audio duration and audio-seconds per processing-second. Distinguish process CPU/RSS from unmeasured accelerator and system-service resources.

The short recording is used for development checks. The human review page includes all three recordings and locally playable audio, comparable transcript panes, optional provider blinding, ratings, notes and exportable judgments. Model disagreement is not ground truth. Word/character error rates require a human-corrected reference and an explicit normalization policy; do not derive them from an existing machine transcript.

## Safety and availability

Copy authorized recordings independently and verify source hashes. Benchmark serially to reduce contention. No provider may upload audio. Do not modify app providers, running bundles, source libraries or user labels. If a requested model is gated or unavailable, report that row as unavailable rather than substituting another backend's performance.

## Results

See [RESULTS.md](RESULTS.md). This experiment informs provider choices; it does not implement app integration.

## Run the comparison

Use macOS 26 or newer on Apple Silicon with the requested Apple speech language assets already installed. Build the standalone optimized executable; this does not rebuild or launch the app:

```sh
swift build -c release --package-path experiments/local-transcription-comparison/native
uv run --no-project --with huggingface_hub python experiments/local-transcription-comparison/download_models.py --root tmp/transcription-comparison/models
```

Prepare Apple assets separately from measured runs. Existing locale reservations are preserved; a full reservation list produces an actionable failure rather than evicting another language:

```sh
experiments/local-transcription-comparison/native/.build/release/LocalTranscriptionComparison --prepare-apple-assets --language zh-CN --output tmp/transcription-comparison/apple-zh-setup.json
experiments/local-transcription-comparison/native/.build/release/LocalTranscriptionComparison --prepare-apple-assets --language en-US --output tmp/transcription-comparison/apple-en-setup.json
```

Keep a private preparation JSON under `tmp/` with `fixtures`: each fixture has a generic `id`, `label`, `language` (`zh-CN` or `en-US`) and `tracks`, each containing `id` and absolute audio `source`. Prepare independent copies once:

```sh
uv run --no-project python experiments/local-transcription-comparison/compare.py prepare --config tmp/transcription-comparison/prepare-config.json --root tmp/transcription-comparison/fixtures
```

A separate private run JSON has a `providers` object with `apple`, `nemotron` and `whisper` entries. Each entry supplies the executable path and `modelRoot`; pinned providers also supply `modelRevision`. Apple uses installed SpeechAnalyzer assets, Nemotron uses the parent folder containing `multilingual/2240ms` and `latin/2240ms`, and Whisper uses the downloaded model folder containing its compiled models and tokenizer files. The executable checks local model and tokenizer assets before timed inference. WhisperKit has an internal tokenizer download fallback if prepared assets change or fail after preflight; keep those assets immutable during a run. No audio is sent to a transcription service.

```sh
uv run --no-project python experiments/local-transcription-comparison/compare.py run --config tmp/transcription-comparison/run-config.json --root tmp/transcription-comparison/fixtures --fixtures short --tracks system
uv run --no-project python experiments/local-transcription-comparison/compare.py page --root tmp/transcription-comparison/fixtures
```

Omit fixture/track filters to run the full prepared set. Existing results are protected; use filters for remaining work and `--iteration-start 1` for a second invocation without replacing the first. The review page uses the latest successful result and exports its exact hash. Use a separate prepared root for an independent dataset. Runs are serial, with a one-hour default process timeout. Run receipts include audio, executable, configuration and runner hashes plus the declared model revision. The separate model-download manifest records each model-file hash; it is not embedded in each run receipt. A failed provider produces a failure receipt without preventing the remaining providers from running.

Open the generated private `review.html` in a browser. Listen to the shared audio, compare the blinded columns, rate accuracy/completeness/faithfulness/punctuation/language switching, and export judgments. Reveal provider names after judging. Notes and corrected reference text stay associated with the audio; ratings are tied to the exact transcript result so a rerun cannot silently inherit old scores. Apple and Whisper supply timed segments. Nemotron groups the pinned SDK's real decoder-emission timestamps when ordering, bounds and exact text checks pass. It keeps whole-recording text when those checks fail. These groups support listening navigation but do not establish word-alignment accuracy.

## Integration boundaries

These are native Swift runtimes suitable for evaluating local providers, not completed app providers. The package requires macOS 26, matching the current app. Apple uses the app's SpeechTranscriber file-analysis API but omits meeting persistence and recovery checkpoints. Nemotron uses the intended Core ML conversion; timing quality, cancellation integration, model installation/update UI and live-stream latency still need production validation. Whisper uses local compressed multilingual large-v3-turbo weights and the public WhisperKit API.

The staged assets occupy about 1.28 GB for both Nemotron vocabulary variants and 630 MB for Whisper plus its tokenizer. Download and compilation-cache storage are additional. FluidAudio is Apache-2.0 and WhisperKit is MIT; model weight licenses are separate from runtime licenses and must be retained/reviewed when packaging providers. The experiment downloads assets into ignored storage and does not redistribute them.

## Validate changes

```sh
uv run --no-project python -m unittest discover -s experiments/local-transcription-comparison -p 'test_*.py'
swiftc experiments/local-transcription-comparison/native/Sources/LocalTranscriptionComparison/NemotronTiming.swift experiments/local-transcription-comparison/native/Tests/NemotronTimingChecks.swift -o tmp/transcription-comparison/nemotron-timing-checks
tmp/transcription-comparison/nemotron-timing-checks
```

Keep benchmark source/binary receipts with results. Native timing diagnostics and display grouping may change without changing ASR model inference; the results document distinguishes the primary serial matrix from later diagnostic runs.
