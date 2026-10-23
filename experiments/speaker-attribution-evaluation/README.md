---
title: Speaker attribution and reference evaluation
date: 2026-10-23
status: in-progress
scope: offline-speaker-experiment
---

# Speaker attribution and reference evaluation

Evaluate whether checking several excerpts prevents a mixed acoustic cluster from inheriting one person's name. Separately compare bounded recognition reference sets and score aggregation on held-out meetings. This experiment does not modify production attribution, enrollment or user libraries.

## Inputs and isolation

Use an immutable, independently copied library, audio and local models. Keep all private paths, identities, annotations, embeddings, receipts and raw results under the repository's ignored `tmp/` directory. Tracked source accepts runtime input paths; synthetic tests contain no user data. Never point the acoustic runner at a live library or model cache. Verify source hashes before and after capture and processing.

## Acoustic comparison

Compare the production one-excerpt-per-cluster baseline with independent turn matching and a bounded multi-excerpt consistency check that expands analysis only for conflicting clusters. Use the same audio, model revision, confirmed references and acoustic segmentation. Exclude the target meeting from enrollment. Freeze sparse human annotations independently of predictions; unlabeled passages are not ground truth.

Report named-speaker attribution accuracy and coverage on annotated excerpts. Diarization error rate requires complete reference speech activity, overlap and identity timelines, so sparse screenshot annotations cannot establish full-recording DER. Retain uncertain and short passages explicitly. Separate a demonstrated improvement on the diagnostic recording from independent validation on other recordings.

Measure optimized Swift runs, including model load, full scan, additional embedding extraction and scoring. Report wall time, CPU time, peak resident memory, extraction counts and cold/warm distinctions. Process RSS includes models, the runtime and test harness; it does not isolate accelerator allocations or energy. Do not include compilation in inference latency.

## Reference-set comparison

Hold out each query's entire meeting from enrollment. Compare caps of 1, 3, 6, 12 and 24 compatible references, reporting actual available counts. Compare maximum cosine, mean scores, a normalized centroid and a top-reference average. Shared thresholds are a controlled ablation, not calibrated equivalence between scoring methods. Report recorded enrollment provenance. A missing automatic-selection receipt cannot establish that a historical example was individually reviewed; keep that uncertainty explicit.

Measure wrong-person assignment, abstention, coverage and correct identity ranking. Unknown-person trials must exclude all references for the held-out identity. Cached embedding scoring time is reported separately from audio processing. The stop-versus-replacement comparison replays retained examples in creation order using all other meetings. This is a retrospective selection ablation, not an online replacement evaluation: true confirmation/deletion timestamps and past rejected enrollment attempts are unavailable. A future chronological evaluation must use only evidence available before each query.

## Run

Use private configuration files under ignored storage. The acoustic configuration supplies independently copied `tracks` (each with `track`, `source`, `path` and `sha256`), `profilesPath`, `modelRoot` and `excludedMeetingIDs`. Profiles contain production-compatible `Person` records prepared with the query meeting excluded; the harness asserts that no reference uses an excluded meeting. Run from the repository root with an isolated source checkout at the reported revision:

```sh
uv run --no-project python experiments/speaker-attribution-evaluation/run_acoustic.py \
  --checkout tmp/isolated-attribution-source \
  --config tmp/attribution-inputs/config.json \
  --output-dir tmp/attribution-results \
  --source-revision BASELINE_COMMIT
```

The runner temporarily installs its harness into the isolated test target, builds optimized release tests, measures each method in a separate invocation and removes the temporary source. Five repetitions share loaded models within each invocation. Compilation is excluded from inference timing. The first inference is cold within the process; filesystem and Core ML caches are uncontrolled.

The reference configuration supplies `snapshot`, `output`, optional `productionMatching` (a frozen production score/profile receipt) and `repeats`. Its default timing runs cached queries 20 times:

```sh
uv run --no-project --with numpy python experiments/speaker-attribution-evaluation/reference_evaluation.py \
  --config tmp/reference-inputs/config.json
uv run --no-project --with numpy python -m unittest discover \
  -s experiments/speaker-attribution-evaluation -p 'test_*.py'
```

Neither runner requires a remote service. Retain private input/model hashes and raw logs alongside outputs; publish only aggregate results.

## Results

See [RESULTS.md](RESULTS.md) for measured findings, exact run commands, source/configuration receipts and limitations. Production changes require separate validation after this experiment.
