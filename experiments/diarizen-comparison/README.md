---
title: DiariZen comparison harness
date: 2026-10-14
status: prepared
scope: experiment
---

# Run locally

Compare the official DiariZen Large-s80-v2 CPU pipeline with the app's Community-1 Core ML pipeline. This is a system comparison: different runtimes and execution devices are part of the measured cost. The model weights permit non-commercial use; this experiment does not establish suitability for commercial distribution.

Run from this directory. `setup.sh` pins upstream code, Python packages, and public model revisions. Downloads, private audio, outputs, and logs stay in ignored `.local/`. The model code is from the official repository, including its bundled pyannote fork. The batch-size override defaults to 4 for the Mac evaluation; upstream uses 32. Thresholds remain unchanged. A recorded patch migrates an upstream deprecated SpeechBrain import without changing inference. The inference-only environment omits upstream training tools and CUDA-only `onnxruntime-gpu`.

```sh
./setup.sh
export UV_CACHE_DIR=/private/tmp/uv-cache
export MPLCONFIGDIR="$PWD/.local/matplotlib"
export XDG_CACHE_HOME="$PWD/.local/cache"
uv run --no-project python prepare.py --target /private/tmp/gday-diarization-review-20261014/target.json --output .local/audio
```

The private pointer contains a `folder` field. Preparation reads recording file metadata and writes anonymous `trackN.wav` files, using FFmpeg mono PCM16 at 16 kHz. Feed these exact WAV files to both engines; do not compare a newly downmixed candidate against a differently prepared archived baseline. Input hashes remain private.

After the coordinator permits heavy inference:

```sh
uv run --no-project python measure.py --output .local/diarizen-process.json -- \
  uv run --no-project --python .local/venv/bin/python python run_diarizen.py \
  --inputs .local/audio/inputs.json --model .local/model \
  --embedding .local/embedding/pytorch_model.bin --output .local/diarizen --threads 4 --batch-size 4
```

Inference runs offline and does not upload audio. It emits RTTM files, stage timing, and `local-result.json` compatible with the app's saved diarization representation. Load the candidate and Community outputs through the same Swift transcript projector against one immutable timed transcript. Do not replace the library's active transcript as part of benchmarking.

```sh
uv run --no-project python summarize.py .local/community/local-result.json .local/diarizen/local-result.json --output .local/acoustic-summary.json
```

The Swift runner uses gated tests that remain disabled in normal CI. Build the release test target before measuring, with `GDAY_DIARIZATION_BENCHMARK` unset:

```sh
bash ../../apps/client-macos-swift/scripts/test-macos.sh -c release --filter DiarizationComparisonHarnessTests
```

Set `MODEL_ROOT` to an existing verified `LocalModels` directory. The runner acquires existing Community-1 models and never requests a download. Once inference is authorized:

```sh
uv run --no-project python measure.py --output .local/community-process.json -- \
  bash run-swift.sh community "$PWD/.local/audio/inputs.json" "$PWD/.local/community" \
  "${MODEL_ROOT:?Set the existing model cache directory}" --direct
```

Community-1 receives the exact manifest WAVs, verifies their hashes, and records the manifest's source mapping independently of anonymous filenames. Speaker clustering still computes its required embeddings. Only the additional voice-example embedding extraction for People Library association is disabled. `stages.json` separates model acquisition from inference. Core ML may lazily initialize compute resources during the first prediction, so acquisition time does not capture every first-use cost. These measurements cover diarization, excluding transcription, transcript projection, People Library association, and app publication; they are separate from the app's complete recording reprocessing run.

`--direct` launches the built test binary with the installed SwiftPM testing helper and the verified Command Line Tools runtime paths. This excludes package discovery and build planning from process CPU/RSS measurements; test startup, input hash checks, and model acquisition remain included. Use `--skip-build` instead on other toolchain layouts, and report its additional SwiftPM startup overhead. No GUI or library mutation is involved.

To compare transcript projections, set `TIMED_TRANSCRIPT` to an immutable canonical transcript JSONL file containing `analysisTrackID` and valid timed spans. Create a private `.local/results.json` array with each candidate's `name` and absolute `path` to its `local-result.json`. Names may contain only letters, digits, hyphens, and underscores. Then run:

```sh
bash run-swift.sh project "$PWD/.local/audio/inputs.json" "$PWD/.local/projections" \
  "${TIMED_TRANSCRIPT:?Set the immutable timed transcript}" "$PWD/.local/results.json" --skip-build
```

This writes private projected transcripts and aggregate row/span attribution counts with the shared transcript hash. These counts measure coverage, not speaker correctness or diarization error rate. Output paths must remain under ignored `.local/` storage. Save the app commit, model revision, thread/device configuration, fresh-process versus warm-run state, and input hashes beside each result. Run each full candidate serially once, then use at least three matched short-window repetitions when feasible. Keep compilation and other model jobs idle during measurement.

See [RESULTS.md](RESULTS.md) for metric definitions, evidence, pending checks, and limitations.

# Listening review

After both outputs and optional projections exist, create a private offline HTML review:

```sh
uv run --no-project python review.py --inputs .local/audio/inputs.json \
  --results .local/results.json --projected .local/projected.json --output .local/review.html
```

`results.json` is an array of `{ "name": "Engine A", "path": "/absolute/local-result.json" }` objects. Optional `projected.json` maps each engine name to its projected transcript JSON array or JSONL file. Omit `--projected` to review raw speaker timelines alone.

Open `.local/review.html` locally. One audio control plays the selected window while both timelines show the same playback cursor. Engine-local speaker labels are not matched identities. Windows rank speech-activity, simultaneous-speaker-count, and boundary-count differences; they are candidates for listening, not measured errors. Optional transcript labels explicitly distinguish automatic attribution from unresolved text. The page uses local relative audio paths, inline code, and no external libraries or network requests. Keep the whole review folder private.
