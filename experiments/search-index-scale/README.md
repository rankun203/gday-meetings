---
title: SQLite search index scale experiment
date: 2026-10-06
status: complete
scope: experiment
---

# SQLite search index scale experiment

Compare the current native app exhaustive search, SQLite exhaustive search,
DiskANN, and USearch HNSW. The current grid grows from 39,066 to 390,660
windows at 384 dimensions. HNSW uses FP32, FP16, and INT8 storage, each with
and without original FP32 candidate reranking. The earlier Vectorlite smoke
check is retained separately and is not the optimized HNSW baseline.
See [RESULTS.md](RESULTS.md) for findings and limitations.

## DiskANN scale run

The new run uses 39,066 authorized 384-dimensional embeddings, then nine
normalized perturbation blocks for 2×–10× growth. Input SQLite access is read-only;
only ignored benchmark files are written. Do not publish vectors or query
receipts derived from a private library. The macOS arm64 extension is pinned and
checksum-verified:

```sh
uv run --no-project python experiments/search-index-scale/prepare_extension.py tmp/diskann-benchmark
UV_CACHE_DIR=/private/tmp/search-index-benchmark-uv \
uv run --no-project --with numpy==2.4.4 --with psutil==7.2.2 \
  python experiments/search-index-scale/diskann.py prepare \
  --library /path/to/library/index.db \
  --output experiments/search-index-scale/runs/diskann-int8
OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 OMP_NUM_THREADS=1 \
UV_CACHE_DIR=/private/tmp/search-index-benchmark-uv \
uv run --no-project --with numpy==2.4.4 --with psutil==7.2.2 \
  python experiments/search-index-scale/diskann.py build \
  --output experiments/search-index-scale/runs/diskann-int8 --scales 10 --hybrid --mutations
```

Use a new output folder for each run. One growing graph is sampled after each
39,066-row block; this measures incremental growth rather than ten independent
full rebuilds. Build batches contain 256 rows. Both exact and DiskANN connections
request a 2 MiB SQLite cache with memory mapping disabled. Search runs in fresh
child processes after each scale. The OS filesystem cache is not flushed.
`pause` and `await-queries` marker files in the output folder allow coordinating
with separate app measurements. Remove those markers to resume the run.

For query-length probes, compile `../embedding-optimization/benchmark.swift`
with `swiftc -O -module-cache-path /path/to/ignored/cache`. Generate inputs with
`query_lengths.py --tokenizer MODEL/tokenizer.json --output PROBES`, then run
`measure_query_lengths.py --benchmark EXECUTABLE --model MODEL/SemanticEncoder.mlmodelc
--probes PROBES --output RUN`. Use `uv run --no-project --with tokenizers` for the
input generator and `--with numpy==2.4.4` for the measurement runner. Run these
before graph construction so the reference rankings include their queries.
Probes use 8, 32, 64, 96, 128, 256, and 512 active tokens; padding remains 128 or
512 according to the model function. Generic repeated text isolates input length;
it is not a semantic relevance evaluation.

Run synthetic lifecycle checks with:

```sh
UV_CACHE_DIR=/private/tmp/search-index-benchmark-uv \
uv run --no-project --with numpy==2.4.4 --with psutil==7.2.2 \
  python experiments/search-index-scale/test_diskann_contract.py \
  tmp/diskann-benchmark/vec0.dylib
```

The harness records total process RSS, its baseline and peak, physical footprint,
CPU time, and Darwin physical disk I/O counters. These are not estimates from
vector payload size. Queries include NumPy/Python result conversion and reranking;
app model load, name matching, source checks, and UI rendering are excluded.
Delete generated databases and binary vector files after retaining aggregate
reports. No production schema migration or backend selection is implied.

## HNSW precision grid

Use the frozen `all.f32`, query embeddings, labels, and exact references from
the completed SQLite fixture. Run each precision sequentially in a fresh
output folder. The runner measures every 1×–10× stage, three query repetitions,
all seven candidate settings, direct compressed ranking and disk-backed FP32
reranking, plus append/delete/replacement and snapshot persistence.
Final ranking is evaluated at 10, 20, 50, and 100 results, separately from
candidate counts. Generate `truth100-{scale}.json` references with
`diskann.truth(output, scale, top=100)` before running the grid.

Each scale also tests 1,000 content candidates combined with all windows for
an identified synthetic speaker, followed by FP32 reranking from disk. This
checks whether preserving the speaker bonus needs additional candidates.
Per-scale graph snapshots permit follow-up searches without rebuilding;
their copying is excluded from graph build and persistence timings.

```sh
UV_CACHE_DIR=/private/tmp/search-index-benchmark-uv \
OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 OMP_NUM_THREADS=1 \
uv run --no-project --with usearch==2.26.4 --with numpy==2.4.4 --with psutil==7.2.2 \
  python experiments/search-index-scale/hnsw.py grid \
  --run experiments/search-index-scale/runs/diskann-int8 \
  --output experiments/search-index-scale/runs/hnsw-f16 --dtype f16
```

Repeat with `f32` and `i8`. Native CPU feature access is required: the runner
rejects `serial` detection because sandbox restrictions can hide ARM features.
FP32/FP16 should report NEON and INT8 a supported native integer path on this
Mac. Do not silently compare a scalar fallback with accelerated app code.

`test_hnsw_contract.py` checks synthetic lifecycle behavior in all three
precisions. `quantization_quality.py --dataset DATASET --queries QUERY_RECEIPT
--documents DOCUMENT_RECEIPT --output REPORT` reuses the labeled retrieval
fixture and native embedding receipts. Document receipts may contain queries
followed by passages, matching `embedding-optimization/prepare.py` order.
Keep those inputs ignored. The output contains aggregate quality metrics only.

Export the aggregate grid with `summarize_hnsw.py RUNS OUTPUT.json`. Incomplete
cells remain marked pending. Separate mutation time from full snapshot writing;
USearch is not a transactional SQLite virtual table. Stop other benchmark
workers before timing a new engine. Retain small receipts and remove disposable
graphs after all comparison and recovery checks finish.

## Earlier HNSW smoke run

From the repository root:

```sh
UV_CACHE_DIR=/private/tmp/search-index-benchmark-uv \
OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 OMP_NUM_THREADS=1 \
uv run --no-project --with numpy==2.4.4 --with vectorlite-py==0.2.0 \
  --with sqlite-vec==0.1.9 \
  python experiments/search-index-scale/benchmark.py \
  --scales 1200 --queries 8 \
  --output experiments/search-index-scale/runs/smoke
```

The current authorized range is 1×–10× of 39,066 windows at 384 dimensions.
The older million-window and 768-dimensional plans are not part of this run.

The suite runs one engine and dimension at a time in separate processes.
Successful case databases and HNSW snapshots are removed after measurements;
small JSON reports and exact-ranking reference files remain. Failed case
files are retained for inspection, and the suite stops. Completed cases are
skipped on restart. Use a new output directory when changing the fixture,
library versions, parameters, or query count.

Generated artifacts under `runs/` are ignored by Git. The script does not read
meeting folders or change the app's database. Extension loading is enabled
only to initialize the two explicitly installed benchmark libraries.

### Smoke resource controls

The suite estimates required free space as 1.5 times the FP32 payload plus
256 bytes per window, then adds a 4 GiB reserve. Cases that fail this check
are skipped. The worker also checks the reserve between insertion batches.
This is a conservative estimate, not a disk quota: a batch or final snapshot
can consume space between checks. Native math thread counts are limited by
the command above; HNSW insertion is sequential. There is no automatic memory
pressure monitor, so review available memory before large runs.

### Smoke outputs

Each engine produces a JSON report containing build and insertion time,
close/persistence time, database and snapshot size, peak process memory,
reopen-plus-first-query time, query p50/p95, and recall@20 with and without a
speaker bonus. JSON progress events go to standard output. Reopening does
not flush operating-system caches and must not be described as a cold-start
measurement.

## Aggregate validation

After completing the grids, regenerate the public reports with
`summarize_diskann.py`, `summarize_hnsw.py`, and `summarize_growth.py`.
Run `uv run --no-project experiments/search-index-scale/validate_measurements.py`
from the repository root to check grid completeness, lifecycle receipts, finite
values, and public-report privacy. The summarizers provide command-line help
for input paths. Keep private frozen vectors and detailed receipts in ignored
`runs/`; generated graph snapshots and SQLite benchmark databases can be
removed after exporting reports and rebuilt using the instructions above.
