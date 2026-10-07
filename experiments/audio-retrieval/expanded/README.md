---
title: Expanded recorded-meeting retrieval benchmark
date: 2026-10-06
status: evaluated-with-limits
scope: reproducible-expanded-evaluation
---

# Design

Use one frozen gallery and query file for every encoder. The expansion retains the original 50 queries, adds 32 bilingual queries grounded in reviewed spans and 20 bilingual decision/status queries grounded in historical text. The latter target changed settings, alternatives and provisional decisions; they are not audio-verified. Translations of one fact share a `fact_id`. Related passages from the same meeting share a scenario. Query wording and declared competing windows must be written before inspecting expanded rankings.

The main gallery has 1,500 historical windows selected by a fixed SHA-256 ordering, with original windows, labeled answers and declared alternatives retained. It adds 177 windows from selected microphone/system excerpts, including the quiet-room follow-up. Those new windows use fresh Apple text; historical windows keep their saved text. This mixed input policy is explicit and identical across encoders. The paired recognition ablation replaces only the new windows and uses identical queries and audio. A shared gallery is not a held-out test set.

# Build and run

Keep a private JSON configuration containing `base` (the original corpus directory), `base_windows`, `additional_queries` (JSONL), `mandatory_competitors`, and `excerpts`. Each excerpt supplies `run`, `id`, `meeting` and `meeting_directory`. The run directory contains the prior audio manifest and Apple receipts. Query records use the original `queries.jsonl` schema and add `cohort`, `fact_id` and evidence provenance. The builder refuses an existing output directory. It writes all private source mappings alongside the corpus.

```sh
uv run --no-project experiments/audio-retrieval/expanded/build.py PRIVATE_CONFIG NEW_DATASET

uv run --no-project experiments/audio-retrieval/expanded/run.py DATASET RUNS \
  --model-cache MODEL_CACHE --e5-model E5_SNAPSHOT
```

Set `UV_CACHE_DIR` to writable temporary storage. Model caches must contain the pinned snapshots. The runner uses offline model loading and executes encoders sequentially with Metal. The encoders use the experiment requirements. Logs preserve compatibility warnings rather than hiding them.

After completion, run `compare.py DATASET RUNS --output COMPARISON`, adding one `--text-run NAME=RUNS/NAME` for each of the six `encode_text.py` names. The comparison emits raw evidence metrics and a method-blinded pooled relevance file. It validates input fingerprints before combining results. Empty recognized windows remain candidates. Every method searches the complete gallery.

For automated graded review, run `expanded/judge.py COMPARISON/blind-pool.jsonl PRIVATE_JUDGMENT_DIRECTORY --env-file SCRIPT_ENV` with `uv run --no-project --with httpx==0.28.1 --with python-dotenv==1.2.4`. It sends the private query–passage pool and fixed reference evidence, not audio, to the configured reference-review service, requests no storage, and records every response and request fingerprint. Method names, scores and positive window IDs are withheld. The rubric distinguishes useful discussion from full support for the requested reference-backed facts. Each batch requires a fixed set of short output keys, mapped locally to immutable review IDs; incomplete or mismatched responses are rejected. Pass the resulting judgments to `compare.py --judgments` only when the complete pool validates. Earlier query-only review was superseded because it could credit a general rule without the requested revised detail. These are reference-conditioned model judgments, not listening verification; inspect the leading models' disagreements separately.

# Interpretation and validation

Report original, human-reviewed and decision/status cohorts separately. Cluster uncertainty by meeting so translations and related facts are not treated as independent samples. Evidence labels are nonexhaustive; a different window may still contain useful evidence. Do not convert a raw label miss into a claim of an outdated decision without reading that returned passage. Likewise, absent words in ASR are not encoder failures. Keep query design, evidence provenance, transcript conditions and actual failure inspection together in the main `RESULTS.md`.

```sh
uv run --no-project --with httpx --with python-dotenv --with numpy --with scikit-learn \
  python -m unittest discover -s experiments/audio-retrieval/expanded -p 'test_*.py'
```

The paired Jina/Granite/Qwen transcription ablation uses `run_variants.py DATASET RUNS WHISPER_RECEIPTS PRIVATE_PATCHES NEW_VARIANT_DIRECTORY`. The patch file maps window IDs to exact `before`/`after` replacements justified by user annotations; each replacement must occur once. Imported text, fresh WhisperX text and review-patched Apple text replace only the 177 new windows. All other texts, every query and every audio file stay fixed. WhisperX's Chinese output receives the worker's `tw2sp` conversion. Word midpoint projection falls back to the segment midpoint when alignment is incomplete. The full patched draft remains provisional, not a complete gold transcript.

`score_variants.py` reports paired evidence metrics and emits a separate blinded first-result pool for the 32 reviewed-span queries. Judge that pool with `judge.py`, then rerun the scorer into a fresh output directory with `--judgments JUDGMENTS_JSONL` to produce `relevance-summary.json`. The scorer counts missing first results as zero and rejects incomplete or duplicate judgments. Its reference-conditioned support review distinguishes finding the timestamp from retaining the requested fact. `summarize.py DATASET RUNS COMPARISON` writes aggregate resource measurements, cohort-specific clustered intervals and the comparison matrix after the full pool is judged. No private transcript wording belongs in the checked-in report.
