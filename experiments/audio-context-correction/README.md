---
title: Contextual audio correction experiment
date: 2026-10-14
status: experimental
---

# Contextual audio correction

Compare two prompts against the same short recording clips: transcription with a vocabulary list, and revision with the same vocabulary plus an existing transcript. The script sends audio to OpenAI and saves responses separately. It never updates a meeting library.

## Run

Install `uv` and `ffmpeg`. Place the authorized input manifest and outputs in the ignored `private/` directory. The manifest contains a `context` string and a `clips` array. Each clip has an `id`, absolute `audio` path, `start` and `end` in seconds, and `original` transcript string. Use unique IDs containing letters, numbers, underscores, or hyphens. Clip times must be finite, nonnegative, and increasing. A synthetic context might list fictional people and environment names; do not put private examples in tracked files.

```sh
UV_CACHE_DIR=/tmp/gday-uv-cache uv run --no-project --with httpx --with python-dotenv \
  experiments/audio-context-correction/run.py \
  --manifest experiments/audio-context-correction/private/manifest.json \
  --env apps/client-macos-swift/.env \
  --output experiments/audio-context-correction/private/new-run \
  --model gpt-audio-1.5
```

The environment file must contain `OPENAI_API_KEY`. The script loads it in-process and does not print it. It always calls the official OpenAI endpoint, uses text-only output, and sets `store` to false. This flag does not replace provider retention policies.

Each run makes two requests per clip, with at most six clips and 180 seconds of distinct source material. Audio is converted to mono 24 kHz PCM WAV. Saved response JSON includes HTTP status, request model, server response, reported usage, and elapsed request time. Existing response files are skipped: choose a new output directory to repeat a measurement. Keep failed attempts when retrying. An HTTP 200 response can still be empty or unusable; inspect the content before scoring.

See [RESULTS.md](RESULTS.md) for the exploratory results and limitations.

Run the input checks without network access or audio conversion:

```sh
uv run --no-project python -m unittest discover -s experiments/audio-context-correction -p 'test_*.py'
```
