---
title: Public speaker capacity stress test
date: 2026-10-08
status: active
scope: live-speaker-capacity-experiment
---

# Purpose

Build short recordings with known public speaker identities to test channel capacity, returning voices, and association mistakes. These synthetic conversations use read speech. They do not establish quality on natural meetings.

The input is OpenSLR LibriSpeech test-clean, distributed under CC BY 4.0. Preparation downloads the official archive and checksum list, verifies the pinned official MD5, and records SHA256 hashes. It retains the source license and README with the private experiment artifacts. No audio, public speaker metadata, transcripts, or generated manifests belong in Git.

# Prepare and validate

Run from the repository root:

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project --with soundfile python experiments/live-speaker-capacity/prepare.py --output tmp/live-speaker-capacity-20261008
UV_CACHE_DIR=tmp/uv-cache uv run --no-project --with soundfile python experiments/live-speaker-capacity/validate.py --manifest tmp/live-speaker-capacity-20261008/manifest.json > tmp/live-speaker-capacity-20261008/validation.json
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python -m unittest discover -s experiments/live-speaker-capacity -p 'test_*.py'
```

The archive download is approximately 346 MB. Preparation freezes `selection.json` before decoding or generating recordings. Speaker selection sorts public IDs by SHA256 of a fixed seed and ID, assigns the first twelve to development, and assigns the next twelve to validation. The groups are disjoint. This custom partition is not the original LibriSpeech development/test split.

Each group receives four recordings shorter than four minutes. `manifest.json` binds audio and ownership references by hash. `ownership.json` records original archive member names, source hashes, source crop frames, output frames, and gains. Model inference must begin only after these receipts exist. Use development outcomes to choose a policy, freeze that policy, then evaluate validation once. Do not tune thresholds or speaker selection on validation results.

Validation reconstructs every output sample from the archived source crops and checks the PCM16 quantization bound. It also verifies disjoint cohorts, source-owner IDs, manifest hashes, exact ownership placements, and digital silence in injected gaps. Its receipt records SoundFile, libsndfile, and NumPy versions.

Archive content is read through named regular members. The script never extracts archive-provided paths. Existing rendered recordings are not overwritten. To repeat preparation, use a new ignored output directory; a verified archive may be copied there to avoid downloading it again.

# Model output and scoring

`replay.py` invokes the parent experiment's production replay driver with installed models and a separately built test bundle. It does not download models or open the meeting library. It verifies the frozen audio and ownership hashes and keeps each attempt separate. Build the instrumented test bundle as described in the [parent README](../speaker-consolidation/README.md), then run development first:

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/live-speaker-capacity/replay.py \
  --manifest "$DATASET/manifest.json" --output "$REPLAY_OUTPUT" \
  --models-data "$MODEL_DATA_DIRECTORY" --package-path "$ISOLATED_PACKAGE" \
  --test-bundle "$TEST_BUNDLE" --cohort development
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/live-speaker-capacity/evaluate_online.py \
  --freeze-policy "$DEVELOPMENT_POLICY"
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/live-speaker-capacity/evaluate_online.py \
  --manifest "$DATASET/manifest.json" --replay-root "$REPLAY_OUTPUT" \
  --policy "$DEVELOPMENT_POLICY" --cohort development --output "$DEVELOPMENT_RESULT"
```

The evaluator rejects failed or incomplete runs, verifies artifact hashes and callback reconstruction, and separates raw live labels, capacity-safe labels, candidate publication labels, and current-state aliases. For validation, first freeze a policy with `--freeze-policy "$VALIDATION_POLICY" --development-evaluation "$DEVELOPMENT_RESULT"`. The validation evaluator requires that hash-bound development result and unchanged method sources. Run and score validation only after choosing the method on development.

To test the preregistered capacity counter, preserve the baseline bundle and matching source snapshot, then use `install_candidate.py --package-path "$ISOLATED_PACKAGE"`. The installer rejects the production worktree and changed baseline sources. It copies the experimental counter and changes the copied evidence revision explicitly. Rebuild the copied test bundle and replay into a fresh directory. See [the candidate design](CAPACITY_POLICY.md); never relabel old evidence or mix candidate output with baseline provenance.

For a standalone hypothesis, export a JSON array of `{ "start": 0, "end": 1, "speaker": "anonymous-group" }` records, in recording seconds. Use the same anonymous group across returns when the tested method associates them.

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/live-speaker-capacity/score.py --ownership tmp/live-speaker-capacity-20261008/development-arrivals-returns/ownership.json --hypothesis tmp/live-speaker-capacity-20261008/hypothesis.json --output tmp/live-speaker-capacity-20261008/score.json
```

The scorer reuses the repository's maximum-weight one-to-one assignment implementation from `experiments/diarization-benchmark/compare_reference.py`. All other scoring code uses the Python standard library. Preparation uses SoundFile and its NumPy dependency.

Read the metric definitions and limitations in [RESULTS.md](RESULTS.md). Ownership intervals describe who supplied each audio crop, including its internal pauses. They are not speech activity annotations. Do not report these scores as diarization error rate or call their complement speaker accuracy.
