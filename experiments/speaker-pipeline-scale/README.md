---
title: Speaker pipeline scale checks
date: 2026-10-08
status: active
scope: synthetic-performance-validation
---

# Speaker pipeline scale checks

Measure production consolidation and reviewed-example conflict detection using synthetic inputs. The runner compiles Swift value algorithms with optimization, records source and binary hashes, and saves generated files in an ignored directory. It does not read recordings or run a voice model.

From the repository root, run:

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/speaker-pipeline-scale/run.py --mode consolidation --output tmp/scale-consolidation
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/speaker-pipeline-scale/run.py --mode conflicts --output tmp/scale-conflicts
```

Each output directory must be new. macOS and the Xcode command-line tools are required. No Python packages are required. Each run writes `receipt.json`, `timing.txt`, the executable, and its compiler cache. Receipts bind the measured executable to source hashes and check that sources did not change during the run.

To compare an older consolidation implementation, save its source under ignored `tmp/` and pass `--consolidation-source tmp/baseline/SpeakerConsolidation.swift`. Other production dependencies remain those in the current checkout; verify compatibility before comparing. The measured baseline source SHA-256 is recorded in [RESULTS.md](RESULTS.md).

The measured baseline can be recovered from commit `1e4d09b2496860edd4c55c5faeb23f0aeb7c394e`:

```sh
mkdir -p tmp/scale-baseline-source
git show 1e4d09b2496860edd4c55c5faeb23f0aeb7c394e:apps/client-macos-swift/Sources/GdayMeetings/Core/SpeakerConsolidation.swift > tmp/scale-baseline-source/SpeakerConsolidation.swift
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/speaker-pipeline-scale/run.py --mode consolidation --consolidation-source tmp/scale-baseline-source/SpeakerConsolidation.swift --output tmp/scale-baseline
```

The conflicts workload compiles the actual `VoiceReviewConflicts` declaration and voice metadata types extracted from production files. Its reference implementation reproduces the previous all-pairs conflict rule. Each size asserts identical conflict sets before reporting a result. It excludes persistence, embedding reads, and profile selection.

The consolidation workload measures increasing sample counts for one local label and increasing local units that can all merge. Each unit is a distinct recording window. All vectors are synthetic, valid, identical 256-dimensional unit vectors. Construction happens outside the timer. These workloads expose repeated coverage scans and complete-link merging costs; they do not measure diarization accuracy. Use the separate [consolidation equivalence runner](../speaker-consolidation/README.md) to compare exact outputs across varied inputs.

## Full People profile path

The opt-in `VoiceLibraryScaleTests` test creates 8,000 confirmed 256-dimensional representations across eight people, persists them in a temporary library, releases hydrated representations, and measures the actual `matchingPeople` call on the main actor. Setup is excluded; representation reads, selection, and release are included. The filesystem cache is unspecified. The test verifies 12 selected samples per person for its single model and is skipped in ordinary test runs.

Run from an isolated macOS package with release resources prepared:

```sh
GDAY_PROFILE_SCALE=1 swift test -c release --filter VoiceLibraryScaleTests
```

Save output under ignored `tmp/`. The line prefixed `GDAY_PROFILE_SCALE_RESULT` contains JSON schema version 1: workload name, example/person/model counts, embedding dimension, per-person/per-model budget, selected counts, elapsed seconds, setup/read inclusion flags, and cache state. Record the checkout revision and build configuration alongside the log. This full-path measurement complements the pure conflict sweep timing.
