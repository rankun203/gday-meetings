---
title: Search index scale and precision comparison
date: 2026-10-06
status: complete
scope: search-index-experiment
---

# Search index scale and precision comparison

## Problem

Search must remain responsive as a personal meeting library grows. The frozen
baseline contains 39,066 windows from 366 meetings. Its 384-dimensional FP32
coordinates occupy 60,005,376 bytes; ten times the corpus occupies 600,053,760
bytes before metadata or graph overhead. Coordinate payload alone does not
establish resident memory, query cost, or update performance.

The [packed-index change](2026-10-06-packed-search-index.md) reduced median
production search from 4.36 seconds to 416 ms on the original library. The
remaining exhaustive search still checks source files and decodes passage
metadata. Faster model inference does not remove those costs.

## Implemented solution

The isolated harness in `experiments/search-index-scale/` compares production
native exhaustive search, sqlite-vec exhaustive search, sqlite-vec DiskANN,
and USearch HNSW. Reproducible instructions, aggregate receipts, and the
coherent comparison are in its [RESULTS.md](../../experiments/search-index-scale/RESULTS.md).
Private inputs, detailed receipts, vectors, and generated indexes remain ignored.
No production ANN backend or schema migration has been introduced.

| Factor | Values |
| --- | --- |
| Dimensions | 384 only |
| Corpus | 39,066 windows × every integer from 1 through 10 |
| HNSW precision | FP32, FP16, INT8; direct ranking and FP32 reranking from disk |
| Query length | 8, 32, 64, 96, 128, 256, 512 active tokens; separate perturbed-corpus probes |
| Final result count | 10, 20, 50, 100; production uses a fixed maximum of 100 with no slider |
| ANN candidate count | 10, 20, 50, 100, 200, 800, 1,000 |
| Ranking | Content; 0.1 speaker boost; 20% eligible subset; speaker-aware candidate union |
| Lifecycle | Open, first query, repeated queries, build, append 1,000, delete 1,000, replace, reopen |
| Measurements | Wall time, CPU, RSS, peak RSS, physical footprint, physical disk I/O, index bytes, recall, score-equivalent recall |

The 1,000-candidate case tests the proposed compact retrieval strategy: search
the compressed graph, read only selected FP32 vectors from disk, rerank, and
return at most 100 results. An additional strategy unions content candidates
with all windows for an identified synthetic speaker before reranking.

Each query cell is repeated. Fresh workers separate query memory from build
buffers. Measurements retain operating-system caches and must not be called
cold-storage tests. Native queries include metadata and source checks;
extension microbenchmarks exclude those app costs. Model inference is measured
separately using the same query-length grid.

USearch 2.26.4 supplies the precision comparison with identical graph settings.
Native CPU feature access is required: floating-point kernels report NEON and
INT8 uses native integer instructions. Sandboxed feature detection returned
serial kernels, which are excluded from performance comparisons. Snapshot
persistence is timed separately from in-memory mutations and included in the
saved-update total. Save/reopen checks do not establish crash or power-loss
durability equivalent to SQLite transactions.

sqlite-vec is pinned to 0.1.10-alpha.4. Its release archive matches upstream
SHA-256 `9c4c3c9fee1cd68d07028f90c9e31b67f13ca1a1737435ae569e8fe7a17b5a91`.
SQLite requests a 2 MiB page cache with memory mapping disabled. The earlier
Vectorlite smoke test remains a harness check; its binary disabled SIMD and
is not the current optimized HNSW comparison.

## Results and validation

Completed native measurements show approximately linear retrieval cost:
416 ms at 1× and 4.04 seconds at 10×. Appending 1,000 vectors took about 178 ms
at 10×; removing them took 29 ms. Separate query tasks with idle drainage
held the 10× measurement process at roughly 151–157 MiB RSS. A continuous-task
probe reached 1.35 GiB because temporary Objective-C allocations accumulated;
that peak is not the steady-state resident index size.
Process RSS excludes the operating system's filesystem cache, which can retain
SQLite pages and still consume system RAM.

A Time Profiler trace attributed 50.8% of sampled CPU weight to JSON decoding,
19.7% to fingerprint work, 5.3% to SQLite, and 0.5% to explicit Accelerate
frames. Other retrieval frames account for 23.0% and may include inlined
vector scoring. These are sampled CPU shares, not wall-time stage timings.

The 102-query, 1,677-passage labeled fixture separates vector compression from
ANN loss. FP16 preserved top-one and top-five rankings. Direct INT8 reduced
hit@5 from 75.5% to 73.5%; FP32 reranking of 20 INT8 candidates restored the
baseline top five on this fixture. With 1,000 INT8 candidates and FP32
reranking, top-100 overlap is 100%; tiny top-20 identity differences are
score-equivalent within 10⁻⁶. This does not establish quality at larger corpus
sizes or for speaker-boosted ranking by itself. The HNSW precision/scale grid
has now completed all 30 cells. At 10×, FP32/FP16/INT8 use about 764/477/335
MiB RSS after loading. INT8 takes 7.2 ms for 1,000 candidates plus FP32
reranking, or 16.8 ms with matching-speaker candidates. The latter recovers
100% of boosted top 20 and 99.5% of top 100. INT8 append plus snapshot takes
660 ms; delete plus snapshot takes 415 ms, almost all snapshot cost. All 30
churn/reopen cells preserve their before/after recall and return no deleted
candidates. The SQLite exact/DiskANN grid also completed all 20 engine/scale cells.

Offscreen production-table measurements at 10, 20, 50, and 100 results showed
76–84 ms warm host/layout time and 2.5–2.9 ms reload time. Only eight cells were
materialized in each case. This does not support a large rendering benefit
from reducing the limit to 20; the user chose fixed 100. These measurements
exclude asynchronous summary lookup, headers, provider/model work, and visible
presentation. The full native retrieval-limit grid has completed all 40
count/scale cells: every one of 440 queries matches the full top-K identity
reference, with maximum score error 5.36 × 10⁻⁷. At 10×, warm retrieval takes
4.26–4.28 seconds across all four result counts, with 172–179 MiB final RSS.
These cases end each query task and allow 200 ms idle time between requests.

The final DiskANN grid at 10× measures 54.50 ms for 1,000 candidates with
FP32 reranking, recovering 97.52% of content top 100. Speaker union takes
22.80 ms and recovers 99.60% of boosted top 100. Content-query RSS is about
60 MiB; the speaker-union worker reaches 74.8 MiB. Appending 1,000 vectors
takes 13.74 seconds; deleting them takes 160.36 seconds. The index occupies
5.81 GB. SQLite exhaustive content retrieval takes 159.42 ms and about 51 MiB.

All grid completeness checks pass: 75,600 HNSW observations, 19,800 SQLite
observations, 2,400 speaker-union queries, 440 native queries, and 50 lifecycle
cells. Known DiskANN lookup and distance failures remain explicit. Descriptive
RSS growth is about 74 MiB per 100,000 windows for INT8 HNSW, versus 184 MiB
for FP32 HNSW. SQLite process RSS is approximately constant; OS cache is excluded.
The preferred next prototype is INT8 HNSW with FP32 reranking and speaker-aware
candidates. The app remains on packed exhaustive search until integration,
metadata hydration, filtering, cancellation, and snapshot recovery are validated.

Synthetic lifecycle probes cover persistence, deletion, reinsertion, and
replacement. DiskANN additionally passed rollback, concurrent-reader commit
visibility, recovery after an uncommitted process exit, rename, and integrity
checks. Its adoption constraints remain:

- Returned distances can retain an underestimated approximate value. Independent
  FP32 candidate scoring is required; raw-distance ranking is excluded.
- Looking up a deleted vector raises an error instead of returning no row.
- Direct vector UPDATE, metadata columns, and partition keys are unsupported.
- Row ID zero is reserved by an internal visited-set sentinel; final fixtures
  use positive IDs and exclude the initial diagnostic run.

The live library changed after vector export. Native timing uses frozen
vectors with representative later metadata trimmed and split to preserve the
original window and meeting counts. It measures decoding and filesystem work,
not semantic alignment between that metadata and those vectors.

## Reasoning

Query latency alone cannot select an index. The comparison measures quality,
resident memory, startup, disk footprint, append/delete cost, and persistence.
FP32 storage, FP16 model compute, and INT8 index quantization are separate
choices. Compression tests do not change the published embedding models.

A small content candidate set can miss passages that should enter the final
results after the speaker bonus. Measuring boosted rankings against exhaustive
references exposes this loss. Speaker-aware candidate union is tested because
increasing ordinary content candidates may not be sufficient.

The intended storage boundary keeps providers responsible for typed embeddings
and storage responsible for candidate retrieval, persistence, updates, and
rebuilding. An in-memory graph with snapshots is not equivalent to SQLite
transactions. No backend is selected until lifecycle and quality constraints
are understood.

## Technical debt

No application schema or compatibility bridge was introduced. The experiment
retains these limits before a production adoption decision:

- Synthetic scaled increments and speaker assignments measure controlled growth,
  not years of independently collected meetings. Validate representative labeled
  queries and confirmed speaker associations before adoption.
- Operating-system caches remain warm. Measure cold-storage behavior separately
  if it becomes a product requirement; fresh-process figures are labeled as such.
- DiskANN prerelease defects require FP32 reranking and constrain deletion and
  filtering semantics. Resolve or reject these constraints before integration.
- USearch uses explicit snapshots. A production implementation would need a
  durable mutation log or a documented rebuild/recovery design.

## Related work

The [task-behavior proposal](../design/2026-10-06-search-index-tasks.md) specifies
one rebuild task, progress reporting, and common status/start/end/duration fields
for all task types. It is a proposal, not an implemented task migration.
App startup and first-query measurements remain in the existing
[packed-index worklog](2026-10-06-packed-search-index.md) and
[startup worklog](2026-10-06-search-startup.md).

## Generated artifact cleanup

After exporting and validating the full grid, removed disposable SQLite
benchmark databases, per-scale HNSW snapshots, obsolete FP32/FP16 graphs,
pilot mutation datasets, duplicate vectors, and the unused Vectorlite source
checkout. Retained aggregate reports, detailed receipts, one frozen vector
input set, the latest INT8 graph, the profiling trace, and the signed app build.
No user library data or installed models were removed.
