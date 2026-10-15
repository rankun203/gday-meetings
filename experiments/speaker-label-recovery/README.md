---
title: Speaker label recovery annotation batch
date: 2026-10-16
status: prepared
scope: experiment
---

# Purpose

Prepare one private annotation batch before testing speaker-label recovery rules. The batch combines previously flagged unresolved text, microphone noise controls, fresh unresolved examples, and fresh previously assigned controls. Existing model labels and acoustic reference clips are provisional evidence, not ground truth. No inference, model downloads, library writes, or remote jobs are required.

# Prepare the batch

Use the original immutable transcription artifact, a saved projected transcript, matching saved acoustic turns, prior feedback, the decoded-audio manifest, and the original copied-audio state. Keep all input paths in local variables rather than tracked files.

```sh
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python experiments/speaker-label-recovery/prepare.py \
  --source "$IMMUTABLE_SOURCE" --projected "$SAVED_PROJECTION" --raw "$SAVED_TURNS" \
  --feedback "$PRIOR_FEEDBACK" --audio "$DECODED_AUDIO_MANIFEST" \
  --original-audio-state "$ORIGINAL_AUDIO_STATE" \
  --output "$PWD/experiments/speaker-label-recovery/.local"
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python experiments/speaker-label-recovery/test_prepare.py
```

The generator writes private `annotation-data.json` and `diagnostics.json`. It verifies decoded audio bytes and each prior feedback audio hash against the original manifest. Duplicate immutable row IDs or target anchors, stale text timing, invalid text ranges, and out-of-bounds source or acoustic timing are rejected.

# Render and label

```sh
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python experiments/speaker-label-recovery/render.py \
  --input "$PWD/experiments/speaker-label-recovery/.local/annotation-data.json" \
  --output "$PWD/experiments/speaker-label-recovery/.local/review.html"
UV_CACHE_DIR=/private/tmp/uv-cache uv run --no-project python -m unittest discover \
  -s experiments/speaker-label-recovery -p 'test_*.py'
```

Open the generated page in a browser. Listen to each clip and its numbered targets, compare the provisional references when useful, and choose a judgment for each target. Use Unsure rather than guessing. Labels save in that browser; Export Labels produces the response file, and Import Labels restores an exported copy. Keep the generated HTML, audio dependencies, and immutable manifest unchanged while collecting labels.

# Data contract

`annotation-data.json` contains `version`, `reviewId`, `inputHash`, `tracks`, and `items`. Tracks provide the source, local audio path, decoded SHA-256, original SHA-256, and duration. Each item has a stable ID, source track, clip interval, context text, targets, and neutral preceding/following acoustic references. Private `partition` and `category` fields are for analysis and must be removed from the embedded review interface.

Each timed target retains its exact immutable source row ID, UTF-16 source range, original start/end, timing granularity, and UTF-16 `contextRange`. `.run` timing describes a coarse phrase rather than a word edge; exclude it from exact word-boundary calibration. Speech-presence controls use `type: clipSpeechPresence`, carry no invented text or word offsets, and ask whether speech is present. Punctuation and whitespace-only targets remain in diagnostics but are excluded from speaker-identity questions.

References have neutral labels and selectable IDs, source-relative start/end, and `previous` or `next` relation. They are nearby acoustic excerpts, not asserted speaker identities. Responses should support a reference match, another speaker, no speech, overlap, uncertainty, and incorrect timing. Preserve the batch fingerprint and exact target IDs when exporting responses.

# Sampling and scoring

Previously flagged clips retain all lexical targets, even when several occur in one clip. Twelve fresh unresolved clips sample the same no-overlap/partial-overlap classes with fixed hash ordering. Four additional fresh, previously assigned controls test regressions in existing labels. The fresh clips and their references avoid every prior feedback interval, development clip/reference, and other fresh clip/reference. Clip selection adds a one-second exclusion buffer. No previously assigned label is presented as correct.

Before scoring exported custom references, check their intervals against private partition boundaries. Quarantine development labels whose custom references intersect held-out clips or references before fitting. Also exclude held-out labels whose custom references intersect development or previously reviewed clips or references from independent validation. Keep both exclusions explicit; do not import held-out identity evidence into fitting. Record exclusions and the remaining denominator.

The held-out partition is fixed before collecting this batch's answers. Keep it hidden from the annotation interface and exclude it from recovery-rule fitting. It is a within-recording holdout, not evidence of cross-recording generalization. Score individual targets, not whole clips containing multiple targets. Evaluate speech presence separately from speaker identity and preserve uncertainty or unusable-reference judgments rather than forcing an identity.

# Evidence limits

The diagnostics compare text timing with final acoustic turns. They cannot tell whether absent overlap arose from speech detection, embeddings, clustering, reconstruction, or transcription timing. No preclustering arrays were saved. See [RESULTS.md](RESULTS.md) for measured support counts and the precise instrumentation boundary before any later inference.
