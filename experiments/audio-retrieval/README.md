---
title: Audio retrieval comparison
date: 2026-10-06
status: evaluated-with-limits
scope: local-retrieval-benchmark
---

# Purpose

Compare text queries against the same audio windows using direct audio embeddings, existing transcript embeddings, lexical retrieval, and fixed rank fusion. This experiment does not change app inference or its index.

Results and the comparison matrix are in [RESULTS.md](RESULTS.md). The active evaluation uses 102 queries and 1,677 windows from 49 meetings. Follow the [expanded procedure](expanded/README.md) to build the frozen corpus, run every encoder, grade the shared pool and compare transcription conditions. The component commands below also support historical runs; their artifacts must not be mixed across input fingerprints.

Inputs and model outputs belong in ignored temporary storage. Never commit private queries, transcripts, recordings, source paths, or library identifiers. The scripts accept the prior evaluation's `queries.jsonl`, `corpus.jsonl`, and `private-manifest.json` formats. Every encoder manifest binds its results to the corpus and query ordering.

The repository ignores `private/`, `models/`, `artifacts/`, `runs/`, and `.cache/` inside every experiment folder, as well as root `tmp/`. Use these locations for local inputs and generated output; keep scripts, synthetic fixtures, and aggregate reports outside them.

# Retrieval methods

- [CLAP HTSAT unfused](https://huggingface.co/laion/clap-htsat-unfused): encode consecutive chunks of at most 10 seconds across each window. Compare maximum chunk similarity and normalized mean chunk embeddings. These are separate, declared methods; no random crop discards part of the evidence.
- [Jina v5 omni nano retrieval](https://huggingface.co/jinaai/jina-embeddings-v5-omni-nano-retrieval): full-window audio and transcript embeddings, with query/document prefixes, real-frame audio masks, and the published last-token pooling. The checkpoint has noncommercial terms; this is a research comparison, not a distribution decision.
- [Multilingual E5 small](https://huggingface.co/intfloat/multilingual-e5-small): existing transcript text, query/passage prefixes, masked mean pooling.
- BM25: fixed `k1=1.2`, `b=0.75`; Latin words and numbers, Chinese characters and adjacent character pairs.
- Word TF-IDF: the same multilingual tokenizer, unigrams and bigrams, sublinear term frequency.
- Character TF-IDF: 2–4 character n-grams and sublinear term frequency.
- Reciprocal rank fusion: fixed equal weight and constant 60. Combine BM25 with E5 transcript, Jina transcript, or Jina audio retrieval. Also combine Jina audio with Jina transcript using the same rule and complete dense rankings. This latter variant was added after earlier outcomes were known; its rule was fixed before inspecting its score. Do not tune weights against these queries.

Lexical methods return only positive-score matches. SHA-256 of the opaque document ID breaks ties consistently without favoring original corpus order. Retrieval performs no query translation, expansion or summarization. The corpus builder uses an explicit transcript condition; the paired ablation replaces only the new excerpt passages with another recognizer’s output. Transcript retrieval timings exclude recognition cost.

# Evaluation protocol

Keep evidence retrieval and judged relevance separate:

1. **Original evidence:** hit rate and actual recall at 1/5/10, full-depth MRR, and MRR at 10. The original labels are nonexhaustive. An unlabeled result is an evidence-label miss, not necessarily irrelevant.
2. **Pointwise relevance:** pool each method's top five, the original positive windows, and one repeatable random control per query. Supply fixed reference evidence, while removing method, rank, score, and positive-window metadata before review. Grade each query–passage pair: 0 unrelated or misleading; 1 related topic without useful evidence; 2 useful partial evidence; 3 a direct match to the requested discussion. A direct discussion match can still be a question without an answer. Record a passage-specific reason for every nonzero grade and an explicit reason for zero grades. Do not infer relevance from shared keywords alone.
3. **Evidence support:** inspect whether a useful passage states the requested fact, supports only part of it, contradicts it, or needs context outside the window. Keep answerability distinct from topic similarity. Preserve short supporting spans and missing-context notes in the private review artifact.
4. **Failure inspection:** inspect leading models’ disagreements against fixed reference evidence. Separate missing ASR content, incorrect details, ambiguous queries and useful unlabeled passages. This qualitative inspection is not an independent listening assessment.
5. **Sensitivity:** report English, Chinese, same-language and cross-language groups; use scenario-clustered bootstrap intervals for paired improvements because queries from one scenario are correlated. Report direct-discussion matches, broader useful results, and actual answer support separately.

The pooled nDCG denominator uses judged documents only. It is not exhaustive-corpus nDCG. Precision at five requires all five returned results to be judged; empty ranks contribute zero. An incomplete pool must fail validation. The assistant's transcript review is not a listening assessment, independent human adjudication, or a second model's judgment. Do not claim to evaluate acoustic style or transcription fidelity from transcript text.

# Running

Use `uv run --no-project` for these standalone experiment scripts. Set `UV_CACHE_DIR` and `HF_HOME` to writable temporary directories. `requirements.txt` records the runtime package versions used in this evaluation; `--with-requirements` supplies them without changing the app's environment. Pinned checkpoint revisions are in `encode.py`. Jina's reviewed model code is explicitly enabled for model and tokenizer loading; do not enable arbitrary remote code for additional candidates without review.

```sh
uv run --no-project --python 3.12 \
  --with-requirements experiments/audio-retrieval/requirements.txt \
  experiments/audio-retrieval/encode.py e5 /private/input /private/output/e5

uv run --no-project --with numpy --with scikit-learn \
  experiments/audio-retrieval/compare.py /private/input /private/output

# After completing the blinded review, include the judgment artifact.
uv run --no-project --with numpy --with scikit-learn \
  experiments/audio-retrieval/compare.py /private/input /private/output \
  --judgments /private/output/judgments.jsonl

uv run --no-project --with numpy --with scikit-learn \
  python -m unittest discover -s experiments/audio-retrieval -p 'test_*.py'
```

Use `--device mps` for GPU inference on supported Macs. The manifest binds resumption to input, script, checkpoint, device, and package hashes/versions. Compare latency only under matching hardware and execution conditions; model download time is not interchangeable with warm inference time.

# Transcript model extension

`encode_text.py` evaluates five fixed candidates: Granite Multilingual R2 97M and 311M, Harrier OSS v1 270M and 0.6B, and Qwen3 Embedding 0.6B. It also measures the original Jina checkpoint with only its text encoder loaded. Exact revisions are in the script. Granite uses its published CLS pooling and empty prefixes. Harrier and Qwen use last-token pooling and one fixed meeting-retrieval instruction on queries; documents have no prefix. Jina retains the original query/document prefixes. Every vector is normalized, and overlength inputs fail rather than silently truncate.

Run models sequentially in separate processes. The runner requires an empty output directory, uses float32 and batch size one, and performs synthetic warmup before timing the corpus. It records checkpoint hashes, parameter counts, loading time, first synthetic inference, per-input timing and token counts, and process/Metal memory sampled every 10 ms. RSS and Metal memory overlap on unified memory; do not add them. These Python measurements do not establish Core ML performance or energy use.

```sh
export UV_CACHE_DIR=/private/tmp/gday-benchmark-uv
export HF_HOME=/private/tmp/gday-audio-benchmark-hf

for model in granite-97m granite-311m harrier-270m harrier-600m qwen3-600m jina-text-only; do
  uv run --no-project --python 3.12 \
    --with-requirements experiments/audio-retrieval/requirements.txt \
    experiments/audio-retrieval/encode_text.py "$model" /private/input \
    "/private/output/text-extension/$model" --device mps || break
done

uv run --no-project --python 3.12 \
  --with-requirements experiments/audio-retrieval/requirements.txt \
  experiments/audio-retrieval/compare.py /private/input /private/output \
  --output /private/output/text-extension \
  --text-run granite-97m=/private/output/text-extension/granite-97m \
  --text-run granite-311m=/private/output/text-extension/granite-311m \
  --text-run harrier-270m=/private/output/text-extension/harrier-270m \
  --text-run harrier-600m=/private/output/text-extension/harrier-600m \
  --text-run qwen3-600m=/private/output/text-extension/qwen3-600m \
  --text-run jina-text-only=/private/output/text-extension/jina-text-only

uv run --no-project --python 3.12 \
  --with-requirements experiments/audio-retrieval/requirements.txt \
  experiments/audio-retrieval/summarize_text.py /private/input /private/output/text-extension
```

The separate output directory preserves the original scores and judgments. Existing review IDs remain stable. Review new pairs without method names or rankings, merge them with the original judgments, and rerun the comparison with `--judgments` before reporting expanded pooled relevance. Evidence-label metrics can be reported without new judgments, but unjudged relevance must never be inferred from them. Maintain one coherent `RESULTS.md`: replace the setup, findings and all affected matrices together when the corpus changes.

For CPU/Metal validation, create a private probe dataset containing unchanged rows for three queries and three passages from the full corpus, retaining their original IDs. Run each model against that subset with `--device cpu`, writing to `/private/output/text-extension/cpu-parity/<model>`. Then run:

```sh
uv run --no-project --python 3.12 \
  --with-requirements experiments/audio-retrieval/requirements.txt \
  experiments/audio-retrieval/verify_text.py /private/input /private/probe-input \
  /private/output/text-extension
```

The verifier checks unchanged input rows, matching checkpoint and preprocessing metadata, cosine agreement above 0.99999, and maximum component difference below 0.0001. Summary and parity outputs remain private; publish aggregate findings in `RESULTS.md`.

To reproduce the audio-plus-transcript addition, rerun the combined comparison command with a fresh `--output` directory. The runner includes `hybrid-jina-audio-transcript` automatically when both Jina embedding sets exist. Retain prior judgments, review newly pooled pairs, and pass the complete merged judgment file through `--judgments`. The historical addition reused existing vectors. The expanded run regenerates all encoders and uses a new complete reference-conditioned pool; consult `RESULTS.md` for its size.

# Real meeting transcription review

Use the [recorded-audio procedure](real/README.md) to prepare ten five-minute excerpts, paired Apple/GPT draft recognition and a private listening queue. The expanded evaluation incorporates the saved annotations and quiet-room follow-up, reruns WhisperX on matching source excerpts and measures retrieval sensitivity. GPT prepares references; it is not an app provider candidate. The main results exclude synthetic speech from model-selection evidence.

# Historical synthetic fixture procedure

This historical pilot is retained for reproducibility and software diagnostics, not the active meeting evaluation. It compared: Apple versus WhisperX transcript input, and paired clean/noisy recordings with corrections, budgets and an unspecified supplier. `asr/generate.py` builds 12 scripted scenarios from six bilingual template families. These are a controlled development pilot, not 12 independent held-out natural meetings. Apple system voices generate the speech, so findings must be checked against real recordings and other voices before comparing recognizers generally.

The 24 recordings contain 144 window instances and 72 queries. Each query searches 36 windows in its target recording language; equivalent English and Chinese scripts are not mixed into one gallery. Forty-eight queries have labeled positive windows. The other 24 request a supplier that has not been selected; retain them for answer-support and abstention evaluation, but exclude them from evidence-hit denominators. The evidence labels identify the intended script passage; they do not prove that ASR preserved its answer.

Run on macOS 26 or later with the English and Chinese SpeechTranscriber assets installed. The standalone Apple harness uses the app's progressive preset, an explicit locale and the audio format requested by SpeechAnalyzer. It requires access to macOS speech services; a sandbox may hide supported locales or produce empty synthesized files. The generator rejects missing or silent speech. It never opens a microphone or modifies the meeting library. Its asset reservation uses a separate benchmark bundle identifier.

```sh
export UV_CACHE_DIR=/private/tmp/gday-benchmark-uv
export HF_HOME=/private/tmp/gday-audio-benchmark-hf
export MPLCONFIGDIR=/private/tmp/gday-asr-matplotlib
export XDG_CACHE_HOME=/private/tmp/gday-asr-cache

# Choose a new ignored output directory for each independent run.
ASR_RUN=tmp/audio-retrieval-asr-pilot
mkdir -p "$ASR_RUN"
uv run --no-project --with numpy experiments/audio-retrieval/asr/generate.py "$ASR_RUN/synthetic"
```

Run all commands from the repository root:

```sh
xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 \
  -module-cache-path /private/tmp/gday-asr-swift-cache \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker experiments/audio-retrieval/asr/Info.plist \
  experiments/audio-retrieval/asr/AppleTranscribe.swift -o "$ASR_RUN/apple-transcribe"

uv run --no-project python experiments/audio-retrieval/asr/run_apple.py \
  "$ASR_RUN/synthetic/recordings.jsonl" "$ASR_RUN/apple-transcribe" "$ASR_RUN/apple-finalized"

# --realtime paces 100 ms packets against a monotonic clock; without it,
# the run measures finalized file-replay text, not live latency.
uv run --no-project python experiments/audio-retrieval/asr/run_apple.py \
  "$ASR_RUN/synthetic/recordings.jsonl" "$ASR_RUN/apple-transcribe" "$ASR_RUN/apple-realtime" --realtime

uv run --no-project --with huggingface_hub \
  experiments/audio-retrieval/asr/download.py "$ASR_RUN"
uv run --no-project --python 3.12 \
  --with-requirements experiments/audio-retrieval/asr/requirements.txt \
  python experiments/audio-retrieval/asr/whisper.py \
  "$ASR_RUN/synthetic/recordings.jsonl" "$ASR_RUN/whisper-model.json" "$ASR_RUN/whisperx"

uv run --no-project --python 3.12 \
  --with-requirements experiments/audio-retrieval/requirements.txt --with opencc==1.2.0 \
  python experiments/audio-retrieval/asr/evaluate.py prepare \
  "$ASR_RUN/synthetic" "$ASR_RUN/evaluation" \
  --apple "$ASR_RUN/apple-finalized" --whisper "$ASR_RUN/whisperx"

for dataset in reference-clean apple-clean apple-noise10db whisperx-clean whisperx-noise10db; do
  for model in jina-text-only granite-311m; do
    uv run --no-project --python 3.12 \
      --with-requirements experiments/audio-retrieval/requirements.txt \
      python experiments/audio-retrieval/encode_text.py "$model" \
      "$ASR_RUN/evaluation/$dataset" "$ASR_RUN/evaluation/$dataset/$model"
  done
done
for dataset in audio-clean audio-noise10db; do
  uv run --no-project --python 3.12 \
    --with-requirements experiments/audio-retrieval/requirements.txt \
    python experiments/audio-retrieval/encode.py jina \
    "$ASR_RUN/evaluation/$dataset" "$ASR_RUN/evaluation/$dataset/jina" --device mps
done
uv run --no-project --python 3.12 \
  --with-requirements experiments/audio-retrieval/requirements.txt \
  python experiments/audio-retrieval/asr/evaluate.py score \
  "$ASR_RUN/synthetic" "$ASR_RUN/evaluation"
uv run --no-project --python 3.12 \
  --with-requirements experiments/audio-retrieval/requirements.txt --with opencc==1.2.0 \
  python -m unittest discover -s experiments/audio-retrieval/asr -p test_evaluate.py
```

WhisperX uses pinned large-v2 on CPU/int8 with explicit `task=transcribe`, not the GPU worker's float16 execution. The explicit task avoids a tokenizer error when the pinned WhisperX version switches languages. Alignment models are downloaded separately and their files fingerprinted. The pinned Chinese alignment config emits a deprecated gradient-checkpointing option warning; this inference-only experiment does not enable training or suppress that warning. The optional TorchCodec decoder also warns about the installed FFmpeg libraries; WhisperX supplies decoded audio arrays instead. Record these dependency limits when reproducing the run.

Projection assigns each timestamped word to the window containing its midpoint. If a segment has incomplete word times, its whole text is assigned by segment midpoint and the fallback is counted. Whitespace is collapsed and spaces between adjacent Chinese characters are removed. Empty recognized windows stay empty. `transcript-quality.json` reports edit distance against the intended TTS script after case/punctuation normalization: English word tokens and Chinese character tokens. Number words and digits are not normalized to a shared numeric form. These are script-relative mismatch rates, not audio-verified ASR error rates. The scorer validates the encoding input fingerprint before using a saved vector.

The `reference-clean` transcript is shared by both acoustic conditions and is encoded once. The timed Apple pilot can use a subset manifest: preserve source recording IDs and audio hashes, and report the exact subset. Keep all acoustic variants and both language versions of a template family together in any future train/development/test split. No retrieval threshold or fusion weight is tuned on this pilot.

Summarize the pilot with `uv run --no-project python experiments/audio-retrieval/asr/summarize.py "$ASR_RUN/evaluation" --live "$ASR_RUN/apple-realtime"`. WhisperX Chinese text receives the worker's OpenCC 1.2.0 `tw2sp` conversion before projection, matching the requested simplified-Chinese output. Raw recognition receipts are preserved. A corrected budget fixture replaces an initial accidental contradiction; the final report uses the corrected recordings only.
