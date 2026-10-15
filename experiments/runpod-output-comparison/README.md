---
title: Compare local output with the deployed RunPod worker
date: 2026-10-15
status: active
scope: experiment
---

# Purpose

Collect a remote result on identical original audio without changing the app library or deploying worker changes. The existing worker always runs transcription and alignment before optional diarization. This experiment requests that complete operation and keeps the response outside the library.

# Run

Set `MEETING_DIRECTORY` and `SETTINGS_FILE` privately in your shell. Do not commit their values. The metadata must identify the original `microphone` and `system` tracks. Preparation copies those files and verifies SHA-256 hashes before and after copying. It reads no credentials and makes no network requests.

```sh
uv run --no-project python run.py prepare --meeting "$MEETING_DIRECTORY" \
  --settings "$SETTINGS_FILE" --language zh-cn --output .local/comparison
```

Review the private `state.json` before submission. Exactly one RunPod provider with Transcription and Speaker Diarization enabled and one Filedrop provider with File Transfer enabled must match. If needed, select their IDs with `--runpod` and `--filedrop` during preparation.

```sh
uv run --no-project --with httpx python run.py submit --output .local/comparison
uv run --no-project --with httpx python run.py poll --output .local/comparison
```

Repeat only `poll` while the job is queued or running. It makes one status request per invocation. Submission uploads the two copied files, then posts the existing shape:

```json
{
  "input": {
    "tracks": [
      {"audio_url": "https://files.example/microphone.opus", "track_name": "track0", "source_type": "mic"},
      {"audio_url": "https://files.example/system.opus", "track_name": "track1", "source_type": "system_mix"}
    ],
    "language": "zh-cn",
    "diarize": true
  }
}
```

Actual track order follows saved metadata, and each source remains associated with its copied file. No callback or library-adoption step runs. Tokens are read from destination-bound Keychain items using a read-only `security find-generic-password` invocation; no credential migration occurs. HTTP redirects are disabled. Tokens remain in memory and are sent only to their configured provider; signed download URLs are sent to the configured worker. Private files have owner-only permissions.

The runner persists submission intent before posting and saves the job ID before polling. It never automatically repeats a submission. If the response is ambiguous, inspect endpoint job history before deciding how to recover; do not create another output directory merely to retry. Failed uploads also stop for inspection rather than silently repeating transfers.

`raw-response.json` preserves the complete status response, including per-word labels and embeddings. `request.json` and `state.json` contain signed capabilities and private identifiers; keep all outputs under ignored `.local` or private temporary storage. Successful uploads expire according to the transfer provider.

# Validation

```sh
uv run --no-project python test_run.py
```

Tests use synthetic inputs, mocked transport and mocked credentials. They verify payload source identity, endpoint validation, submission-intent persistence, refusal to resubmit ambiguous jobs, and preservation of returned word labels.

# Comparison limits

The deployed worker returns labels assigned to transcript words and segments, not raw acoustic speaker turns. Compare final output attribution on matched time windows, retaining unresolved and overlapping evidence. Anonymous speaker IDs must be matched by audio/time evidence; equal label strings across engines do not identify equal people. This result cannot establish raw acoustic diarization error rate. Transcription and alignment differences remain part of a full-output comparison.

# Compare and listen

Use the exact locally projected JSONL file retained for this experiment. The state file maps copied tracks to sources and audio hashes.

```sh
uv run --no-project python compare.py --local "$LOCAL_PROJECTED_JSONL" \
  --remote .local/comparison/raw-response.json --state .local/comparison/state.json \
  --out .local/comparison/comparison.json
uv run --no-project python review.py --local "$LOCAL_PROJECTED_JSONL" \
  --remote .local/comparison/raw-response.json --state .local/comparison/state.json \
  --comparison .local/comparison/comparison.json --output .local/comparison/review.html
uv run --no-project python -m unittest discover -p 'test_*.py'
```

Open the generated private `review.html` locally. It provides native audio controls, arbitrary review windows, an initial two-minute window, and windows with the largest final-label differences. It does not reconstruct acoustic turns from assigned words.

The comparison maps anonymous speakers independently within each track using maximum-weight one-to-one overlap. Conditional agreement uses only mutually single-speaker intervals; coverage, unresolved intervals, and ambiguous overlaps are reported separately. It does not infer a missing word label from its parent segment or treat RunPod as ground truth. See `RESULTS.md` for the completed measurements and the proposed tuning sequence.
