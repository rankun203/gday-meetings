---
title: Community-1 configuration ablations
date: 2026-10-15
status: prepared
scope: experiment
---

# Purpose

Compare pinned Community-1 defaults with a smaller segmentation hop while holding every other setting fixed. A separate optional profile retains overlapping output. No production configuration changes, model downloads, library writes, or reference-label claims are part of this experiment.

# Build without downloads

From the repository root:

```sh
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python experiments/community1-tuning/build.py
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python experiments/community1-tuning/test_harness.py
```

The build checks the app's existing FluidAudio checkout at revision `21493f8dac5a97e65742e6ff26f42f164c2fda0f`. It copies source into ignored `.local/package`, changes only package dependency locations to cached local paths, and builds `Community1Benchmark` in release mode with two jobs. The optional Rust binary target uses the existing cached artifact; the disabled text-processing trait remains disabled. Missing caches fail rather than download. The original checkout and app build products are unchanged.

# Profiles

| Profile | Segmentation step ratio | Exclusive output | Changes from default |
| --- | ---: | --- | --- |
| baseline | 0.2 | Yes | None |
| dense | 0.1 | Yes | Segmentation hop only |
| overlap | 0.2 | No | Output overlap only |

`OfflineDiarizerConfig.default` has a ten-second window, so the hop changes from two seconds to one second. Embedding duration, overlap exclusion for embeddings, clustering, VBx, and postprocessing gap settings remain unchanged. Each run records the complete reflected configuration and pinned revisions. The configuration-only test verifies exactly one changed field in each ablation, without loading models.

# Prepare and run

For the existing app cache, run `uv run --no-project python experiments/community1-tuning/prepare_models.py "$CACHED_REVISION_DIRECTORY"`. This verifies all 21 catalog assets using SHA-256 or Git-blob SHA-1 as declared by the app, then creates model symlinks and a manifest in ignored `.local/models`. It never writes the cache. Set `MODEL_DIRECTORY` to that staged directory containing `manifest.json`, `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc`, and `plda-parameters.json`. The runner checks model revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`. Set the input variables to authorized local source files. Do not put their paths in tracked files.

```sh
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python experiments/community1-tuning/run.py \
  --model-directory "$MODEL_DIRECTORY" --audio "$MICROPHONE_AUDIO" "$SYSTEM_AUDIO" \
  --output "$PWD/experiments/community1-tuning/.local/plan"
```

This writes a private plan only. After inference is authorized, use a new output directory and add `--execute`. The default profiles are `baseline dense`, run serially in fresh processes per track. The overlap profile is opt-in with `--profiles overlap`; run it separately after reviewing the first ablation. Do not compile or run competing inference during measurement.

The runner records original input hashes. Because the native loader cannot open these Opus containers, it decodes each source once with FFmpeg to 48 kHz float PCM WAV, preserving channels, matching the app’s intermediate sample format. It records decoded hashes, sample counts, sample rates, and decode preparation time separately (decoding, metadata inspection, and hashing); both profiles receive identical decoded bytes before FluidAudio’s native 16 kHz conversion. FFmpeg and the app’s Opus decoder are not assumed byte-identical. The runner exports per-track resource/stage metrics and raw turns. `results.json` references normalized `LocalDiarizationResult` files for the shared transcript projector. Each normalized result retains track identity and concurrent turns. No speaker is asserted to be a named person. Model loading, audio conversion, preparation, inference, and process totals have different scopes; compare corresponding metrics.

Private artifacts stay under `.local`. Keep the immutable timed-transcript input fixed across candidates. Projection assignment is coverage, not accuracy; comparisons to remote final word labels are conditional agreement, not raw acoustic agreement or DER. See [RESULTS.md](RESULTS.md).

# Project and compare

Use the original immutable transcription artifact, not a previously projected transcript. `PROJECTOR_CHECKOUT` must contain the already-built release test bundle with `DiarizationComparisonHarnessTests`. `REMOTE_RESPONSE` and `AUDIO_STATE` refer to the saved completed worker response and copied-audio manifest. These commands run projection and scoring only:

```sh
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python experiments/community1-tuning/project.py \
  --run "$PRIVATE_RUN" --projector-checkout "$PROJECTOR_CHECKOUT" \
  --source-artifact "$IMMUTABLE_SOURCE" --remote "$REMOTE_RESPONSE" --state "$AUDIO_STATE"
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python experiments/community1-tuning/summarize.py \
  --run "$PRIVATE_RUN" --remote "$REMOTE_RESPONSE"
```

The projector writes canonical JSONL for each candidate. The comparison reports conditional final-label agreement and missing coverage. The summary then restricts agreement to identical baseline/dense/remote single-speaker support, holds both global mappings fixed, and verifies that every original text unit is preserved exactly once. The original and decoded audio hashes are rechecked after inference. Outputs and executable provenance remain private.
