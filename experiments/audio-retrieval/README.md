---
title: Audio retrieval comparison
date: 2026-10-06
status: evaluated-with-limits
scope: local-retrieval-benchmark
---

# Purpose

Compare text queries against the same audio windows using direct audio embeddings, existing transcript embeddings, lexical retrieval, and fixed rank fusion. This experiment does not change app inference or its index.

Results and the comparison matrix are in [RESULTS.md](RESULTS.md).

Inputs and model outputs belong in ignored temporary storage. Never commit private queries, transcripts, recordings, source paths, or library identifiers. The scripts accept the prior evaluation's `queries.jsonl`, `corpus.jsonl`, and `private-manifest.json` formats. CLSP comparison reuses its saved `reference-similarities.npy`, with the original corpus and query ordering.

The repository ignores `private/`, `models/`, `artifacts/`, `runs/`, and `.cache/` inside every experiment folder, as well as root `tmp/`. Use these locations for local inputs and generated output; keep scripts, synthetic fixtures, and aggregate reports outside them.

# Methods fixed before relevance review

- CLSP: existing full-window audio embeddings, retained as the reference.
- [CLAP HTSAT unfused](https://huggingface.co/laion/clap-htsat-unfused): encode consecutive chunks of at most 10 seconds across each window. Compare maximum chunk similarity and normalized mean chunk embeddings. These are separate, declared methods; no random crop discards part of the evidence.
- [Jina v5 omni nano retrieval](https://huggingface.co/jinaai/jina-embeddings-v5-omni-nano-retrieval): full-window audio and transcript embeddings, with query/document prefixes, real-frame audio masks, and the published last-token pooling. The checkpoint has noncommercial terms; this is a research comparison, not a distribution decision.
- [Multilingual E5 small](https://huggingface.co/intfloat/multilingual-e5-small): existing transcript text, query/passage prefixes, masked mean pooling.
- BM25: fixed `k1=1.2`, `b=0.75`; Latin words and numbers, Chinese characters and adjacent character pairs.
- Word TF-IDF: the same multilingual tokenizer, unigrams and bigrams, sublinear term frequency.
- Character TF-IDF: 2–4 character n-grams and sublinear term frequency.
- Reciprocal rank fusion: fixed equal weight and constant 60. Combine BM25 with E5 transcript, Jina transcript, or Jina audio retrieval. Do not tune weights against these queries.

Lexical methods return only positive-score matches. SHA-256 of the opaque document ID breaks ties consistently without favoring original corpus order. No translation, query expansion, summarization, or re-transcription is performed. Transcript-based results are conditional on the existing ASR output; they do not measure the cost or accuracy of producing it.

# Evaluation protocol

Keep evidence retrieval and judged relevance separate:

1. **Original evidence:** hit rate and actual recall at 1/5/10, full-depth MRR, and MRR at 10. The original labels are nonexhaustive. An unlabeled result is an evidence-label miss, not necessarily irrelevant.
2. **Pointwise relevance:** pool each method's top five, the original positive windows, and one repeatable random control per query. Remove method, rank, score, and positive-label metadata before review. Grade each query–passage pair: 0 unrelated or misleading; 1 related topic without useful evidence; 2 useful partial evidence; 3 a direct match to the requested discussion. A direct discussion match can still be a question without an answer. Record a passage-specific reason for every nonzero grade and an explicit reason for zero grades. Do not infer relevance from shared keywords alone.
3. **Evidence support:** inspect whether a useful passage states the requested fact, supports only part of it, contradicts it, or needs context outside the window. Keep answerability distinct from topic similarity. Preserve short supporting spans and missing-context notes in the private review artifact.
4. **Pairwise review:** compare selected top results with methods and rank scores hidden. Allow ties and both-irrelevant outcomes. Reverse left/right order on a subset to check order sensitivity. Treat this as a consistency check by the same judge, not independent human validation.
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

Use `--device mps` for GPU inference on supported Macs. The manifest binds resumption to input, script, checkpoint, device, and package hashes/versions. Compare latency only under matching hardware and execution conditions; model download time and prior CLSP app measurements are not interchangeable with warm inference time.
