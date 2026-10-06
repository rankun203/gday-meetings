---
title: Core ML embedding optimization
date: 2026-10-06
status: evaluated-with-limits
scope: embedding-latency-experiment
---

# Purpose

Compare pinned Granite 97M and 311M Core ML conversions for interactive search. Keep generated models, token inputs, vectors, private retrieval data, and timing receipts in ignored storage. Do not upload evaluation inputs. Published mixed-FP16 variants preserve the original FP32 artifacts and tags.

# Run

Use the locked `apps/worker-search/coreml` environment. Select full Xcode for the Core ML compiler without changing the machine-wide developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer UV_CACHE_DIR=/private/tmp/gday-semantic-uv \
uv run --project apps/worker-search/coreml python experiments/embedding-optimization/convert.py \
97m OUTPUT --cache MODEL_CACHE --precision selective --tokens 512

swiftc -O experiments/embedding-optimization/benchmark.swift -o BENCHMARK
BENCHMARK MODEL.mlmodelc PROBES.json all OUTPUT.json
```

`PROBES.json` contains `ids`, `mask`, and optional `reference` vectors. The harness uses native Core ML, batch one, and synchronous prediction, matching the app's inference path. Run only one timed model process at a time. `all`, `gpu`, `ane`, and `cpu` select allowed compute units; `ane` allows CPU fallback and does not establish actual Neural Engine execution. Repeat in fresh processes; retain the first run separately because Core ML execution-plan caches affect load time.

Use `--from-package SELECTIVE_MODEL.mlpackage --precision selective --palette 6` to evaluate post-training K-means palettization on the selective-FP16 weights. The precision and token arguments must describe that input package. These conversions use coremltools' weighted `kmeans1d` path for large FP16 tensors. FP32 palette conversion instead needs scikit-learn and is not part of the completed comparison. The published FP32 packages provide the baseline. Shorter fixed input shapes require a 512-token fallback for longer queries and passages; never truncate queries to achieve a speedup.

`--precision bounded-mask` is an experimental ModernBERT variant. It bounds both attention masks at −10,000 before conversion, keeps mask selection/clipping and output normalization in FP32, and allows attention additions, softmax and layer normalization to use FP16. The override targets the pinned Transformers implementation; revalidate it before changing dependencies.

Prepare private evaluation inputs and compare native outputs with:

```sh
uv run --project apps/worker-search/coreml python experiments/embedding-optimization/prepare.py \
  TOKENIZER_FOLDER DATASET INPUT_DIRECTORY
BENCHMARK BASELINE.mlmodelc INPUT_DIRECTORY/full-512.json all BASELINE.json
BENCHMARK CANDIDATE.mlmodelc INPUT_DIRECTORY/full-512.json all CANDIDATE.json
uv run --project apps/worker-search/coreml python experiments/embedding-optimization/compare.py \
  DATASET BASELINE.json CANDIDATE.json COMPARISON.json
```

For a 128-token candidate use `queries-128.json` and `compare.py --query-only`. Add `--documents FULL_CANDIDATE.json` to test a rebuilt 512-token document index alongside that query encoder. Check `inputs.json` first: this comparison requires every query to fit. The dataset uses the local audio-retrieval experiment's `queries.jsonl` and `corpus.jsonl` schema. Do not publish those inputs or the native JSON files containing vectors. The comparison outputs contain aggregate metrics only. `measurements.json` retains the aggregate results used in `RESULTS.md`.

`run_matrix.py CONFIG OUTPUT_DIRECTORY --repeats 3` runs sequential fresh processes. CONFIG has a `benchmark` executable path and `models` entries with `name`, `model`, `probes`, and `units` (for example `["all"]`). Use the same six short synthetic probes for both token shapes in latency comparisons. Retain the seventh, long probe for fixed-512 numerical checks. `summarize.py OUTPUT_DIRECTORY SUMMARY.json` reports medians and ranges across runs. `compute_plan.py MODEL.mlmodelc PLAN.json` records planned device preferences; it does not trace actual execution.

# Shared-weight deployment

Combine validated conservative selective-FP16 packages after both function shapes pass retrieval checks:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer UV_CACHE_DIR=/private/tmp/gday-semantic-uv \
uv run --project apps/worker-search/coreml python apps/worker-search/scripts/package_granite_coreml.py \
  QUERY_128.mlpackage PASSAGE_512.mlpackage TOKENIZER_FOLDER OUTPUT_DIRECTORY
BENCHMARK OUTPUT_DIRECTORY/SemanticEncoder.mlmodelc INPUT_DIRECTORY/queries-128.json all QUERY_OUTPUT.json query128
BENCHMARK OUTPUT_DIRECTORY/SemanticEncoder.mlmodelc INPUT_DIRECTORY/full-512.json all PASSAGE_OUTPUT.json passage512
```

The optional final benchmark argument selects a named Core ML function. Compare these outputs with the separate source packages before upload. The deployment uses `mixed-fp16/` within each existing model repository and the `mixed-fp16-v1` tag; this is mixed floating-point precision, not low-bit weight quantization. See RESULTS.md for pinned publication revisions.

# Gates

Check finite values and embedding drift before retrieval tests. A minimum cosine of 0.9999 is the strict parity target. Compressed variants that miss it require retrieval evidence rather than automatic acceptance. Compare query and passage embeddings at identical token limits against the FP32 reference, including mixed old-index/new-query vectors. Report top-1 agreement, top-5 overlap, and labeled evidence recall separately. A speed improvement does not authorize silently mixing vector spaces or replacing released models.

# Authorized library validation

`validate_library.swift` is an opt-in Swift Testing harness for the release app's actual indexing and search path. Copy it into the isolated checkout's `Tests/GdayMeetingsTests` directory. Set `GDAY_SEARCH_VALIDATION_DATA_DIR` to an authorized library, `GDAY_SEARCH_VALIDATION_QUERIES` to a local JSON array of queries, and `GDAY_SEARCH_VALIDATION_REPORT` to an ignored output path. Run the release test filtered to `RealLibrarySearchValidationTests`, using the repository test script's Swift Testing plugin flags. With no environment variables, it does nothing.

The harness writes the disposable search index and reusable embeddings in the selected library. It records private query text and result excerpts in the local report, so never publish that report. Compare aggregate latency and result identities between implementations with the same model, queries, library snapshot, and result limit. The initial indexing time includes model preparation; a projection rebuild that reuses saved embeddings is a different measurement from fresh model inference.
