---
title: Local speaker review
date: 2026-10-01
status: experimental
scope: independent-audio-annotation
---

# Local speaker review

Listen to prepared clips and mark anonymous speaker ranges before comparing diarization systems. The interface hides predictions, transcripts, source coordinates, and diagnostic selection categories during annotation.

From the repository root:

```sh
UV_CACHE_DIR="$PWD/tmp/uv-cache" uv run --no-project python -B \
  apps/experiments/diarization-review/server.py
```

Open <http://127.0.0.1:8766>. The default input is `tmp/diarization-evaluation/review`, containing one directory per sample with `blind/annotations.json`, clip WAV files, and a separate `private/key.json`. Use `--review-dir` to select another prepared set under root `tmp/`, or `--port` to change the local port. Create review sets with the [benchmark review tools](../../../experiments/diarization-benchmark/EVALUATION.md).

# Review a clip

1. Listen to the audio. Drag across the waveform to select speech, or enter exact start and end times.
2. Assign an anonymous speaker number. The dropdown includes Speakers 1–20; choose **Add Speaker** for more. Keep the same number for the same voice across clips within a sample. Add a separate range for each voice during overlapping speech. Number keys 1–9 remain shortcuts; use the dropdown for higher numbers.
3. Replay or loop the selection, adjust its edges, and use Undo to correct edits. Save a short speaker reference to compare a voice across clips.
4. Mark audio you cannot confidently annotate as uncertain.
5. After checking the full clip, choose **Finish Clip & Next**. This explicitly marks the clip reviewed. Uncertain ranges stay outside evaluation; other unlabeled audio counts as silence.
6. When the sample is reviewed, choose **Export Reviewed Sample** to score the systems on independently sampled clips. Diagnostic clips are excluded from the score.

Edits save automatically. If another tab changes the sample, choose **Save My Draft** to preserve your changes under `tmp/`, then load the saved annotations before continuing. Drafts require manual reconciliation; they do not overwrite the saved review. Completion is a reviewer action; neither opening a clip nor saving labels proves that someone listened.

The comparison labels the saved reference **Saved Server**. **Local Model 1**, **Local Model 2**, and subsequent labels follow the order of `--model` arguments used when preparing the set. The private key preserves their source paths and hashes.

# Data and limits

The server binds to `127.0.0.1`. It serves only the application assets and bounded review endpoints. Media, annotations, backups, scores, screenshots, and caches belong under the repository's ignored `tmp/` directory. The app uses no external scripts or hosted services.

Scores describe the checked audio. They do not establish accuracy across other meetings, or the quality and timing of labels delivered during live transcription. Saved server transcript assignments remain a comparison system, not independent ground truth.

# Validation

Run the synthetic backend checks from the repository root:

```sh
UV_CACHE_DIR="$PWD/tmp/uv-cache" uv run --no-project python -B \
  apps/experiments/diarization-review/test_server.py
node --check apps/experiments/diarization-review/static/app.js
```

The tests generate temporary audio and annotations under root `tmp/`. Browser validation uses synthetic tones and does not count as human annotation of meeting audio.
