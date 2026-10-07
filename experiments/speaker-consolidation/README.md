---
title: Retained voice embedding consolidation evaluation
date: 2026-10-08
status: experimental
scope: production-speaker-consolidation
---

# Retained voice embedding consolidation

This experiment replays prepared audio through the production Nemotron adapter and voice embedding extractor, then calls the production consolidation engine. It compares live labels and consolidated labels with frozen worker output and independently reviewed excerpts. See [RESULTS.md](RESULTS.md) for measurements and limits.

Inputs, installed model copies, embeddings, and raw results belong in an ignored `tmp/` directory. No step uploads audio or changes the meeting library. The replay test is disabled unless explicitly enabled by the driver.

## Prepare and build

The preparation script consumes the existing private diarization evaluation layout. It verifies audio and frozen annotation hashes, checks worker-output timestamps against the saved references, and copies installed model files into the experiment directory. It keeps reference labels from the raw worker output, before person association.

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project python -B \
  experiments/speaker-consolidation/prepare.py \
  --evaluation-root "$PRIVATE_EVALUATION" \
  --installed-models "$INSTALLED_MODELS" --output "$PRIVATE_OUTPUT"
```

Build the app's tests in an isolated checkout with the repository's normal native dependencies. The test target must contain `SpeakerConsolidationReplayTests`. Use the resulting package path below; `run.py` uses `--skip-build` and never changes the running app. Its default is Debug; use `--configuration release` when release tests are built. Build configuration is recorded, and Debug times must not be presented as release performance.

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project python -B \
  experiments/speaker-consolidation/run.py --manifest "$PRIVATE_OUTPUT/manifest.json" \
  --package-path "$ISOLATED_PACKAGE" --sample sample-J --rollover off
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project python -B \
  experiments/speaker-consolidation/run.py --manifest "$PRIVATE_OUTPUT/manifest.json" \
  --package-path "$ISOLATED_PACKAGE" --sample sample-J --rollover on
```

Repeat for the other manifest samples. Attempts are immutable: use a fresh output directory to repeat a run. Model loading occurs before the replay clock. The receipt separates embedding extraction time, replay time, and clustering time.

To keep inference independent of later builds, copy the built product directory and matching production sources into private storage. Pass `--test-bundle` with the copied `GdayMeetingsTests.xctest` and use the copied source package as `--package-path`. This invokes the installed Swift Testing helper directly and records the copied binary and source hashes.

## Score

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project python -B \
  experiments/speaker-consolidation/evaluate.py --manifest "$PRIVATE_OUTPUT/manifest.json" \
  --output "$PRIVATE_OUTPUT/evaluation.json"
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project python -B \
  experiments/speaker-consolidation/test_score.py
```

The scorer reuses the exact-interval and optimal speaker mapping implementation from `diarization-benchmark`. It includes zero and 250 ms boundary-exclusion views, with overlap included and excluded. Saved worker gaps are unknown. Only human-reviewed regions establish silence. Speaker mappings span an entire sample or review category; mappings are never fitted separately to each clip. Random clips and speaker-coverage clips remain separate.

`score.py` can also score one evidence/result pair against a reference containing `audioDurationSeconds`, `intervals`, and optional `reviewedRegions`.

## Repeat clustering without audio inference

To reproduce rejected sample-level grouping, compile the preserved experimental implementation with shared production types, then change only its threshold:

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/build.py --tool excerpt \
  --output "$PRIVATE_OUTPUT/consolidate"
"$PRIVATE_OUTPUT/consolidate" "$PRIVATE_EVIDENCE" "$PRIVATE_RESULT" 0.72
```

Threshold sensitivity on the scored recordings is exploratory. It cannot establish held-out calibration. Embeddings from different encoders, revisions, or preprocessing contracts must remain separate.

`calibrate.py` instead reserves one declared sample for threshold selection. It tries the fixed grid 0.55–0.90 against that sample's full saved worker reference, selects minimum disagreement, and freezes the result before scoring other recordings. This is calibration to a silver reference; improvement must still be assessed on held-out human-reviewed speech.

Freeze and apply calibration with hash-bound output:

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/calibrate.py --manifest "$PRIVATE_OUTPUT/manifest.json" \
  --runner "$PRIVATE_OUTPUT/consolidate" --output "$PRIVATE_OUTPUT/calibration"
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/evaluate.py --manifest "$PRIVATE_OUTPUT/manifest.json" \
  --runner "$PRIVATE_OUTPUT/consolidate" --calibration "$PRIVATE_OUTPUT/calibration/calibration.json" \
  --output "$PRIVATE_OUTPUT/evaluation-calibrated.json"
```

The evaluator retains the initial threshold result alongside the calibrated result. `diagnose_samples.py` scores the identical retained-sample support to separate grouping errors from propagation and unresolved fallback.

## Replay limits

Replay uses chronological 16 kHz blocks and the production sampling, activity filtering, rollover, and embedding code. It awaits every offered sample's extraction and bypasses the capture queue. This measures ideal retained-sample coverage and offline replay cost. It does not measure concurrent transcription, the live controller's busy-skip behavior, capture backlog, thermal endurance, or energy. The experiment must not claim those properties from accelerated replay.

New replays also write `availability.json`. Its ordered entries retain every published speaker event and completed embedding sample ID, with the upper bound of audio submitted at that callback. The one-second input blocks bound this clock's resolution. An embedding's acoustic end time is not its availability time. Event ordinals preserve callbacks sharing the same submitted-audio timestamp. Final stream-flush callbacks retain the final audio endpoint. The trace measures sequential replay availability, not concurrent recording latency. Run receipts bind the trace and replay test source by SHA-256. New runs also hash the test binary, production sources, and model assets before and after execution; changed inputs invalidate the attempt. Mutable validation caches and Finder metadata are excluded from model inputs.

Unresolved consolidated activity retains an anonymous local label during scoring. It is not removed to make the error smaller. Unresolved duration is reported separately. The scorer's fallback naming must be checked against final app publication behavior before interpreting its scores as transcript behavior.

## Evaluate causal live association

`online_associate.py` is an experimental chronological association policy, not production app behavior. It compares a changing match with a sticky first match at the frozen 0.72 threshold. Each trusted channel accumulates only previously available samples. Candidate identities come from earlier completed windows; known same-source overlap prevents a merge. Reference annotations enter only after decisions are complete.

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/online_associate.py \
  --manifest "$TRACE_OUTPUT/manifest.json" --output "$ONLINE_OUTPUT" \
  --availability --samples sample-J sample-D
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/test_online_associate.py
```

With `--availability`, the script verifies trace hashes, exact activity/window reconstruction, and sample references. Samples wait until a published continuity event confirms their trusted range. Candidate labels at publication use decisions from strictly earlier callback ordinals. Current-state snapshots separately apply an available alias to that local label's earlier published speech. They do not claim the identity was known when that speech first appeared. Activity after capacity remains in a distinct unresolved namespace; a capacity-safe local baseline separates that change from association gains.

Without a trace, the script uses sample end plus a declared delay. Those results are algorithmic sensitivity checks, not observed publication behavior. Extra-delay trace variants retain the original evidence-confirmation callback and do not simulate a concurrent scheduler. Use the zero-additional-delay trace variant for the observed callback-order comparison. Neither mode measures controller busy skips or wall-clock latency.

## Inspect short-span preprocessing

`EmbeddingAudit.swift` re-extracts four fixed chronological samples from the prepared WAV, checks their cosine similarity to retained vectors, and measures filterbank means. It reconstructs the original feature path and compares an active-frame centering probe with the corrected production extractor. Active-frame centering and zeroed padding are now the production v2 contract. They fix the measured padding behavior, while the separate accuracy results show that sample-level grouping still fails; v1 and v2 vectors must remain incompatible.

Compile it with the production extractor and its supporting types:

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/build.py --tool audit \
  --output "$PRIVATE_OUTPUT/embedding-audit"
"$PRIVATE_OUTPUT/embedding-audit" "$PRIVATE_OUTPUT" "$SAMPLE_ID" \
  "$PRIVATE_EVIDENCE" "$MODEL_DIRECTORY" "$PRIVATE_OUTPUT/embedding-audit.json"
```

Run local model inference with normal CoreML runtime permissions. A sandbox-constrained timeout is not a completed accuracy run; restart it in a fresh output directory and retain its failure receipt separately.

## Re-extract after a preprocessing correction

`Reextract.swift` calls the current production extractor on every retained span. `reextract.py` verifies unchanged activity, sample IDs, timestamps, and quality; requires a changed embedding compatibility type; and writes separate evidence and receipts. Original replay and extraction times remain historical fields; `reextractionSeconds` measures only the new extraction after model loading.

Compile with `build.py --tool reextract --output "$PRIVATE_OUTPUT/reextract"` through `uv run --no-project`. Then run:

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/reextract.py --manifest "$PRIVATE_OUTPUT/manifest.json" \
  --extractor "$PRIVATE_OUTPUT/reextract" --runner "$PRIVATE_OUTPUT/consolidate" \
  --models "$MODEL_DIRECTORY" \
  --production-source apps/client-macos-swift/Sources/GdayMeetings/Core/CommunityVoiceEmbeddingExtractor.swift \
  --output "$CORRECTED_OUTPUT"
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/calibrate.py --manifest "$CORRECTED_OUTPUT/manifest.json" \
  --runner "$PRIVATE_OUTPUT/consolidate" --output "$CORRECTED_OUTPUT/calibration" \
  --thresholds .10 .20 .30 .40 .50 .55 .60 .65 .70 .72 .75 .80 .85 .90
```

Freeze corrected calibration before running the evaluator against the corrected manifest. G remains the primary control; J was used in preprocessing diagnosis and must be identified as diagnostic. Do not reuse original vectors' calibrated threshold after changing their preprocessing contract. The audit driver explicitly reconstructs the original uncentered graph input and compares it with both its corrected probe and the current production extractor.

## Evaluate channel continuity as a separate method

`ChannelConsolidate.swift` implements the earlier receipt-only experiment. It treats one rollover-protected local identity as one unit, averages its compatible corrected embeddings, and clusters units with complete-link agglomeration. Same-source overlapping activity prohibits a merge. Its CLI requires the corrected evidence, unchanged original evidence, successful rollover-on receipt, result, audit, and threshold. It rejects saturated no-rollover provenance and changed timestamps or activity.

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/build.py --tool channel \
  --output "$PRIVATE_OUTPUT/channel-consolidate"
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/channel_evaluate.py --manifest "$CORRECTED_OUTPUT/manifest.json" \
  --original-root "$PRIVATE_OUTPUT" --runner "$PRIVATE_OUTPUT/channel-consolidate" \
  --output "$CORRECTED_OUTPUT/channel-calibration" --calibrate sample-B-coverage
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/channel_evaluate.py --manifest "$NEW_CORRECTED_OUTPUT/manifest.json" \
  --original-root "$NEW_REPLAY_OUTPUT" --runner "$PRIVATE_OUTPUT/channel-consolidate" \
  --output "$NEW_CORRECTED_OUTPUT/channel-validation" \
  --calibration "$CORRECTED_OUTPUT/channel-calibration/calibration.json"
```

Freeze B calibration before evaluating newly selected D/C recordings. `test_channel_consolidate.py` exercises continuity, cross-channel merging, overlap constraints, and rejection of invalid provenance. The audit separates unresolved speaker-time and activity assigned under the within-channel continuity assumption; unobserved voice changes are not verified by this assumption.

Run the channel-method checks against that exact compiled binary:

```sh
CHANNEL_CONSOLIDATE_RUNNER="$PRIVATE_OUTPUT/channel-consolidate" \
  UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/test_channel_consolidate.py
```

## Audit reviewed silence and audio alignment

`audit_review.py --evaluation-root "$PRIVATE_EVALUATION" --sample "$SAMPLE_ID" --output "$PRIVATE_AUDIT"` verifies frozen hashes, completed review metadata, exact PCM identity for every clip at its stored source offset, and valid speech/coverage bounds. It reports reviewed and uncertain duration separately. Run it through `uv run --no-project`. This checks annotation provenance and alignment; it does not replace another human review.

## Validate the production trusted-window policy

Fresh replay evidence must include actual window provenance recorded by the adapter. Never infer trusted intervals from old UUIDs or add them to historical evidence. The final method accepts only samples fully inside a window's trusted range, which ends when eight channels become established. It assigns only observed activity within that range and leaves later or unsupported activity unresolved.

`TrustedChannelConsolidate.swift` invokes the actual production `SpeakerConsolidation` engine. Compile it with `build.py --tool trusted --output "$TRUSTED_OUTPUT/trusted-channel-consolidate"` through `uv run --no-project`. Keep the earlier experimental binary and receipts separate. The rejected sample-level implementation is retained only as `ExcerptSpeakerConsolidation.swift` under this experiment; `--tool excerpt` builds its runner.

```sh
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/channel_evaluate.py --manifest "$TRUSTED_OUTPUT/manifest.json" \
  --original-root "$TRUSTED_OUTPUT" --runner "$TRUSTED_OUTPUT/trusted-channel-consolidate" \
  --method trusted-channel-mean-complete-link-v1 \
  --output "$TRUSTED_OUTPUT/calibration" --calibrate sample-B-coverage
UV_CACHE_DIR=/private/tmp/uv-speaker-consolidation uv run --no-project \
  experiments/speaker-consolidation/channel_evaluate.py --manifest "$TRUSTED_OUTPUT/manifest.json" \
  --original-root "$TRUSTED_OUTPUT" --runner "$TRUSTED_OUTPUT/trusted-channel-consolidate" \
  --method trusted-channel-mean-complete-link-v1 \
  --output "$TRUSTED_OUTPUT/evaluation" --calibration "$TRUSTED_OUTPUT/calibration/calibration.json"
```

The fresh replay bundle must include the corrected extractor and window collector. The same evidence is both current and original input to this wrapper; no re-extraction or fabricated provenance is needed. Scoring still retains anonymous local labels for unresolved intervals and measures acoustic timelines, not transcript publication.

## Consolidation implementation equivalence

Run the pinned baseline and optimized core against 192 synthetic configurations:

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/speaker-consolidation/compare_implementations.py --output tmp/consolidation-equivalence
```

The runner compiles the production core and the baseline from commit `1e4d09b` together, renaming only the baseline enum. It compares complete speaker results exactly and duration audits within `1e-9` seconds. Inputs exercise ties, overlapping activity, duplicate activity, sample overlap with activity, capacity cutoffs, unknown labels, incompatible embeddings, and input order. It does not run models or use meeting data. The ignored receipt records source hashes, compiler version, and the comparison result.
