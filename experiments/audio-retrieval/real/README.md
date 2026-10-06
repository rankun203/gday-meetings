---
title: Real meeting transcript review
date: 2026-10-06
status: awaiting-listening-review
scope: real-audio-reference-review
---

# Purpose

Use GPT-Live-Transcribe to help improve reference transcripts for retrieval evaluation. It is not an app provider candidate. Compare its draft with finalized Apple SpeechTranscriber output on real meeting audio to locate reference gaps. Produce a private listening queue for content GPT transcribes that is not found in nearby Apple output. Agreement skips user review but is not verified ground truth. This selection is a development sample, not a held-out test set.

# Inputs and privacy

Keep the selection, source paths, audio, transcripts, service events, and review files in an ignored local directory. Repository documents contain anonymous sample IDs and aggregates only. No library file or app provider setting is changed. The OpenAI runner sends the selected audio to OpenAI using the explicitly supplied script environment file; it does not read app Keychain entries. Do not print or copy credentials into receipts.

The private selection is a JSON array. Each record has `id` (an anonymous label), `language`, `setting`, `start`, `duration`, and `sources`, an array of `{id, path}` objects. Use `microphone` and `system` source IDs where available. Include the same source interval for both recognizers. Check that the meeting is finished before selecting it. Historical transcripts are not assumed to be Apple output.

# Run

Run from the repository root. `prepare.py` decodes each selected interval to mono 24 kHz PCM16 without denoising or gain normalization. It verifies excerpt duration and records a SHA-256 hash. Both recognizers receive these same decoded samples; Apple's harness converts to the format required by SpeechAnalyzer.

```sh
REVIEW_RUN=tmp/real-asr-review
uv run --no-project experiments/audio-retrieval/real/prepare.py \
  "$REVIEW_RUN/selection.private.json" "$REVIEW_RUN/audio"

xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 \
  -module-cache-path /private/tmp/gday-asr-swift-cache \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker experiments/audio-retrieval/asr/Info.plist \
  experiments/audio-retrieval/asr/AppleTranscribe.swift -o "$REVIEW_RUN/apple-transcribe"

uv run --no-project experiments/audio-retrieval/real/transcribe.py \
  "$REVIEW_RUN/audio/recordings.jsonl" apple "$REVIEW_RUN/apple" \
  --apple-binary "$REVIEW_RUN/apple-transcribe"

uv run --no-project --with websocket-client==1.9.2 --with python-dotenv==1.2.4 \
  experiments/audio-retrieval/real/transcribe.py \
  "$REVIEW_RUN/audio/recordings.jsonl" gpt "$REVIEW_RUN/gpt" \
  --env-file apps/client-macos-swift/.env --pace 4 --jobs 4

uv run --no-project --with opencc-python-reimplemented==0.1.7 \
  experiments/audio-retrieval/real/review.py \
  "$REVIEW_RUN/audio/recordings.jsonl" "$REVIEW_RUN/apple" \
  "$REVIEW_RUN/gpt" "$REVIEW_RUN/review"

# Remove equivalent wording before asking for listening review.
uv run --no-project --with httpx==0.28.1 --with python-dotenv==1.2.4 \
  experiments/audio-retrieval/real/triage.py \
  "$REVIEW_RUN/review/review.json" "$REVIEW_RUN/triage" \
  --env-file apps/client-macos-swift/.env

# Preserve the initial queue while rendering the focused review.
mkdir "$REVIEW_RUN/focused"
cp "$REVIEW_RUN/review/review.json" "$REVIEW_RUN/review/summary.json" "$REVIEW_RUN/focused/"
ln -s ../review/clips "$REVIEW_RUN/focused/clips"
uv run --no-project --with opencc-python-reimplemented==0.1.7 \
  experiments/audio-retrieval/real/render_review.py \
  "$REVIEW_RUN/focused" "$REVIEW_RUN/triage/judgments.json" --priority-meeting m10

```

Output receipts and generated review files are not overwritten. Rendering refuses an existing review package to protect human annotations; use a fresh review directory with the input queue, summary and clip links when regenerating. To resume, create a manifest containing only unfinished source tracks and use the same output directory. Keep failed receipts separately. The Apple harness needs access to installed Speech assets; an empty supported-locale list inside a sandbox does not establish that the OS lacks support.

# Protocol

Apple uses `timeIndexedProgressiveTranscription`, locale `zh_CN` or `en_US`, complete five-minute excerpts, and accelerated 100 ms packet replay. Only finalized segments enter the comparison. This uses the app's recognizer and preset but is not the historical live transcript and does not measure live latency.

GPT uses the documented `gpt-live-transcribe` alias over the Realtime transcription WebSocket, PCM16 at 24 kHz, requested `delay=high`, no server turn detection, no noise reduction, and no transcript, name, or keyword prompt. Chinese recordings get `languages=[zh,en]`; English recordings get `[en]`. Each source track retains one session; every 20 seconds of audio is explicitly committed. Final events are reconciled by `item_id`. Four-times replay and waiting for each final result make this an offline accuracy protocol, not a natural live timing test. Fixed turn boundaries can split utterances; full-session or silence-aware comparisons remain a follow-up.

The model supplies no word timestamps, speaker labels, or confidence scores. Review timestamps are submitted turn boundaries. Save requested and resolved session settings, model alias, audio hash, events, and package versions. The current service accepts the delay request but does not echo a delay value in its resolved session event; do not claim independently verified delay enforcement. The service alias is not a frozen model snapshot.

# Review and interpretation

`review.py` compares GPT turns with Apple words from both meeting tracks in the same interval plus two seconds of boundary context. Content already captured on the other Apple track does not request review. It normalizes Unicode, case, punctuation, and traditional/simplified Chinese, then aligns Latin words and Chinese characters. Inserted or replaced GPT token spans absent from nearby Apple text enter the queue. Apple-only words and common isolated hesitation sounds do not request review. GPT-empty turns are counted separately.

This is a conservative lexical discrepancy filter, not semantic adjudication: equivalent wording and number formatting can still be flagged, while reused words can hide a changed relationship. `triage.py` sends the selected paired text to OpenAI GPT-5.6 Luna with medium reasoning and a strict JSON schema. It suppresses apparent equivalent wording, formatting and fillers, but retains uncertain meaningful changes. This is a text-only review filter, not a third recognizer or an audio correctness judge. Exact quote and ID checks reject invented highlights or missing decisions. It can still suppress a real difference; retain every raw candidate and model response for audit.

`render_review.py` writes a `PRIORITY-REVIEW.md` when an anonymous priority meeting is supplied, plus `FOCUSED-REVIEW.md` and a shorter `START-HERE.md`, selecting one item per meeting by factual priority and quote length. Exact duplicate focus quotes at the same meeting time are grouped across tracks, with both audio links retained. This is prioritization, not representative accuracy sampling. `REVIEW.md` remains the unfiltered lexical queue. The final files provide paired text, focused review questions and playable audio clips. `paired-transcripts.md` retains all text; `review.json` retains pending decisions and corrected-text fields. After listening, distinguish recovered speech, GPT error, equivalent wording, and unclear audio. Do not turn unchecked agreement or unreviewed GPT output into gold labels or use it to claim ASR accuracy.

After annotation, curate a private decisions JSON with `annotation_sha256` (SHA-256 of the exact annotated Markdown bytes) and `items`. Each item has its queue `id`, the original annotation, an interpretation with unresolved details, and `spans` containing `text` and `evidence` (`audio_review` or `context_only`). Keep disjoint corrections separate. A preference for one recognizer does not approve all its words. Keep names supplied from participation rather than hearing as context-only evidence.

```sh
uv run --no-project experiments/audio-retrieval/real/apply_review.py \
  "$REVIEW_RUN/focused/focused-review.json" "$REVIEW_RUN/focused/START-HERE.md" \
  "$REVIEW_RUN/references/round-01-decisions.private.json" \
  "$REVIEW_RUN/references/round-01"
```

The output directory must be new. It contains an exact annotation snapshot, curated decisions, audio-review spans, unannotated items and counts. The importer validates the source hash and IDs, excludes context-only spans, and labels exports as partial with coarse timing. Curation remains a human interpretation to audit against the preserved notes. An annotated item may still contain unresolved content; the unannotated queue is not a list of all unresolved spans. No full reference transcript or retrieval labels are inferred.

# Quiet room excerpts

Use `select_quiet.py AUDIO IMPORTED_TRANSCRIPT_JSONL NEW_OUTPUT_DIRECTORY` with `uv run --no-project --with numpy` to select 12 quiet 40-second transcript gaps outside the first six minutes. The script records every candidate and the energy/coverage arrays. It ranks low-level signal and sparse timestamp coverage, not detected speech. Its coverage proxy uses the largest individual segment overlap per second. Inspect the selection before recognition; retain silence and failed recognition as outcomes.

A known interval can instead be supplied directly through the existing selection manifest. Run `prepare.py` and both recognizers as above. Then use `render_room.py RUN_DIRECTORY IMPORTED_TRANSCRIPT_JSONL NEW_OUTPUT_DIRECTORY` with NumPy to generate a private comparison document with original and louder clips. The louder copies are listening aids only. This view includes Apple/GPT agreements absent from the imported transcript without requiring users to annotate those agreements. Its optional correction fields do not imply that all passages need review. Keep the original review package unchanged.

# Validation

```sh
uv run --no-project --with opencc-python-reimplemented==0.1.7 \
  python -m unittest discover -s experiments/audio-retrieval/real -p 'test_*.py'
```

The synthetic text fixtures test only the discrepancy filter; they are not synthesized speech or benchmark inputs. Read the main [results](../RESULTS.md) for sample composition, progress, and measurement limits.

# References

The [OpenAI Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription) specifies the session configuration, final-event matching, language hints, and timestamp limitations. The [model page](https://developers.openai.com/api/docs/models/gpt-live-transcribe) identifies the requested model; model availability and aliases can change. The existing [Apple harness](../asr/AppleTranscribe.swift) records its OS, locale, preset, packet interval, and events.

The text-only triage uses [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna) and [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs). This stage compares meaning without listening; it does not establish which transcript is correct.
