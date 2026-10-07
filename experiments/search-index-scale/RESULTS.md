---
title: Search index scale and precision findings
date: 2026-10-06
status: complete
scope: experiment-results
---

# Search index scale and precision findings

## Findings

The experiment compares the app's exhaustive search at commit `e1fbb7f`,
SQLite exhaustive search, SQLite DiskANN, and HNSW at **384 dimensions**, from
39,066 through 390,660 windows. The grid is complete. Quantized HNSW
is measured at FP32, FP16, and INT8, with and without FP32 reranking from
disk. The subsequent app integration is documented in the
[HNSW worklog](../../docs/worklogs/2026-10-07-hnsw-search.md); the matrices below
retain their original measurement boundaries and baseline revision.

The raw FP32 vectors occupy 60,005,376 bytes at 1× and 600,053,760 bytes at
10×. These figures exclude graph edges, metadata, allocator overhead, and
loaded models. The measured exhaustive baseline streams meeting batches from SQLite rather
than retaining all vectors in one array. Actual process memory must therefore
be measured separately from payload size.
Process RSS and physical footprint exclude the operating system's filesystem
cache, which may retain pages after repeated searches. Low process RSS does
not mean those cached pages consume no system memory.

Content candidates alone do not preserve speaker-boosted ranking. At 10×,
DiskANN with 1,000 candidates recovers 97.52% of content top-100 IDs but only
19.63% of boosted top-100 IDs. Unioning 200 content candidates with every
identified-speaker window recovers 99.60% of boosted top 100 at 22.80 ms.
This does not establish behavior for every person frequency or multiple people.

DiskANN update cost and API correctness remain adoption gates. At 10×,
appending 1,000 vectors takes 13.74 seconds and deleting them takes 160.36
seconds, including checkpoint time. Deletion scans graph nodes to remove
references. Direct updates, metadata columns, and partition keys are unsupported
in this prerelease. Returned distances require independent FP32 recomputation;
a missing-row point lookup after deletion raises an error instead of no row.

HNSW FP32, FP16, and INT8 pass the small synthetic save/reopen, persistent
deletion, reinsertion, and batch-deletion probes. The labeled compression-quality comparison is complete: FP16 preserves all
top-one and top-five results on this fixture; INT8 needs FP32 candidate
reranking to recover that agreement. The 30-cell precision/scale grid is complete; INT8 with FP32 reranking cuts
10× process RSS from 764 to 335 MiB while recovering 99.5% of the boosted
top 100 with speaker-aware candidates. Passing these probes does
not establish transaction recovery or production readiness.

## References

- [HNSW](https://arxiv.org/abs/1603.09320) uses a layered neighbor graph to
  reduce the number of distances evaluated. Connectivity and search breadth
  trade memory and computation for recall.
- [USearch](https://github.com/unum-cloud/usearch) implements HNSW with
  compressed vector storage and explicit snapshot persistence. This experiment
  pins Python package 2.26.4 and checks the selected native instruction path.
- [Vectorlite](https://github.com/1yefuwang1/vectorlite) exposes an in-memory
  HNSW graph through SQLite. The earlier 0.2.0 smoke binary reported SIMD
  disabled; its small-fixture timings are not the current optimized baseline.
- [sqlite-vec 0.1.10-alpha.4](https://github.com/asg017/sqlite-vec/releases/tag/v0.1.10-alpha.4)
  supplies the pinned exhaustive and DiskANN virtual tables. Its
  [DiskANN source](https://github.com/asg017/sqlite-vec/blob/v0.1.10-alpha.4/sqlite-vec-diskann.c)
  and [tests](https://github.com/asg017/sqlite-vec/blob/v0.1.10-alpha.4/tests/test-diskann.py)
  explain the graph update and candidate-distance paths inspected here.
- [LibSQL vector search](https://docs.turso.tech/features/ai-and-embeddings)
  is a separate SQLite-fork implementation. It is not measured here.
- [SQLite WAL](https://www.sqlite.org/wal.html) provides database transaction
  behavior; an external HNSW snapshot does not acquire those guarantees merely
  by being used alongside SQLite.

## Experiment setup

### Shared data and grid

The frozen base contains 39,066 authorized, normalized 384-dimensional
embeddings. Each additional block perturbs the base with Gaussian noise
(standard deviation 0.04/√384), then normalizes it. Seed 20261007 fixes growth.
This creates challenging near neighbors, not independent new real meetings.
Private vectors and metadata remain in ignored folders.

Every integer scale from 1× through 10× is measured. Queries include 32
perturbed corpus vectors and four generic repeated-text probes at each of
8, 32, 64, 96, 128, 256, and 512 active tokens. Query embeddings are computed
once and shared across engines. The extended grid repeats each query three
times per candidate setting. The text probes test input-length costs, not
semantic quality of long natural questions.
Every retrieval query still has 384 coordinates. Retrieval differences between
token-length buckets reflect the resulting query vectors and search paths;
they do not demonstrate a direct token-count cost in the index algorithm.

| Factor | Values |
| --- | --- |
| Corpus size | 39,066 × 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 |
| HNSW vector storage | FP32, FP16, INT8 |
| Final result limit | 10, 20, 50, 100 |
| ANN candidates | 10, 20, 50, 100, 200, 800, 1,000 |
| Search breadth | max(128, 2 × candidates) |
| Ranking | Content, speaker boost 0.1, 20% eligible subset |
| Precision ablation | Compressed distance; original FP32 candidate reranking |
| Changes | Append 1,000; delete those 1,000; replace 10; delete entry node |
| Lifecycle | Build, open, first query, repeated queries, persist, reopen after changes |
| Resources | CPU time, RSS, peak RSS, physical footprint, physical disk reads/writes, index bytes |

SQLite uses a 2 MiB connection cache, memory mapping disabled, and WAL.
DiskANN uses INT8 neighbor quantization, 32 neighbors, and insertion breadth
64. This is a compact graph configuration, not an exhaustive parameter search
or the extension's default configuration. HNSW uses connectivity 32 and
construction breadth 128. Math and insertion run on one thread. Timed engines
run sequentially in separate processes, with other user applications left
running. Operating-system caches are not flushed.
Each extension worker opens one index per scale and then evaluates candidate
counts in increasing order. Its first query for a later candidate count can
reuse pages touched by earlier counts; it is not a fresh-open measurement.
The native result-count grid uses a fresh process for each count and rotates
count order between scales.

USearch's compressed graph is resident. FP32 reranking reads only selected
vectors from the original disk file using positional reads; it does not retain
a second full FP32 array. Snapshot writing is reported separately from graph
mutation and included in the saved-update total. The test verifies saving
and reopening, not crash or power-loss durability. These are explicit
snapshot semantics, not SQLite transaction semantics.
The positional-read prototype uses a flat vector file. A production reranker
using SQLite vector rows or incremental BLOB reads would need a separate
integration measurement; these timings do not include that lookup overhead.

### Native app and model timing boundaries

The native harness calls `SemanticSearchIndex.search` from baseline commit `e1fbb7f`,
including source fingerprints, metadata decoding, cosine scoring, and boosting
before top-result selection. The first grid measured top 5 and top 100 at every scale. The follow-up
measures final limits 10, 20, 50, and 100 with separate query tasks and an
additional synthetic result-layout probe.
The live library changed after vector export, so representative metadata was
trimmed and split to retain 366 meetings per base block. Its encoded payload
is within 0.1% of the original 23.3 MB. Frozen vectors remain identical across
engines, but this metadata fixture does not preserve original semantic pairing.

Extension query timings exclude the app's source checks, metadata processing,
name matching, model inference, and UI. The native provider harness excludes
model inference and UI. The separate [startup measurements](../embedding-optimization/STARTUP.md)
include the app and model. Do not equate these timing boundaries.

### Metrics and quality

**Recall@5** is the fraction of exact top-five IDs recovered. References score
the full corpus before selecting results. **Score-equivalent recall** matches
reference scores within 10⁻⁶ to distinguish tied IDs from ranking loss.
For direct compressed-distance paths, this also reflects quantized score
error; use identity recall to assess their ranking and the FP32-reranked
paths to assess full-precision score agreement.
**Boosted recall** uses full-corpus cosine plus the speaker bonus, not a
content-only reference. Synthetic person assignments use `(rowID / 107) % 97`;
queries identify one person. Filtering retains IDs divisible by five.
The candidate-grid filter is applied after retrieval, so it measures the
loss from filtering an overfetched content list. It does not evaluate a
backend-native prefilter implementation or establish that a backend lacks
one. The speaker-union strategy is measured separately.

**p50/p95** are latency percentiles. Fresh-process open and first query are
reported separately; a fresh process is not a cold filesystem cache. Resource
counters measure the benchmark process. Physical disk counters can be zero
when reads hit cache or writes remain buffered. RSS, physical footprint, and
OS cache are different quantities and must not be added indiscriminately.

The existing retrieval fixture has 102 queries and 1,677 passages. Compression
checks first perform exhaustive search over each stored precision, then HNSW
with and without original-vector reranking. **Hit@k** finds any labeled passage
within k results; **evidence recall@5** counts the fraction of labeled positives
found; **MRR** is reciprocal rank of the first labeled positive. Labels are
nonexhaustive. Candidate-limited MRR treats a missing labeled result as zero.
Top-one agreement and top-five overlap compare against unchanged FP32 ranking.

## Results

The machine-readable reports retain per-size and per-query-length cells,
resource observations, and unsupported behavior. The [completeness check](validation_summary.json)
passes all 30 HNSW precision/scale cells, 20 SQLite engine/scale cells,
75,600 HNSW query observations, 19,800 SQLite query observations, 2,400
speaker-union queries, 440 native queries, and 50 lifecycle cells. Known
DiskANN contract failures are recorded explicitly, not counted as successes.

### Vector compression and labeled quality

The [quality aggregate](quantization_measurements.json) reuses 102 queries
and 1,677 passages encoded by the installed selective-FP16 97M model. Only
stored vector precision changes; model weights and query text remain unchanged.

| Method | Labeled hit@1 | Labeled hit@5 | Evidence recall@5 | Top-one agreement | Top-five overlap |
| --- | ---: | ---: | ---: | ---: | ---: |
| FP32 exhaustive reference | 56.86% | 75.49% | 74.51% | 100% | 100% |
| FP16 exhaustive compressed vectors | 56.86% | 75.49% | 74.51% | 100% | 100% |
| INT8 exhaustive compressed vectors | 57.84% | 73.53% | 72.06% | 93.14% | 90.59% |
| INT8 HNSW, 20 candidates, FP32 reranking | 56.86% | 75.49% | 74.51% | 100% | 100% |

The INT8 hit@1 improvement does not imply overall improvement: hit@5 declines
and rankings change. Reranking 20 candidates restores the top five here but
only 90.69% of the full top-20 set. Reranking 100 candidates yields 99.95%
top-20 overlap and restores baseline labeled hit@20. Candidate recall still
matters after score correction. These small-corpus results do not establish
large-scale HNSW recall. With 1,000 INT8 candidates and FP32 reranking,
top-100 overlap is 100% on this fixture. Tiny top-20 identity differences
are score-equivalent within 10⁻⁶; the aggregate records both measures.

The unchanged FP32 reference finds labeled evidence for 80.39%, 82.35%,
87.25%, and 90.20% of queries within 10, 20, 50, and 100 results respectively.
More results expose additional labeled passages; labels are nonexhaustive
and this is not a usability measure of how many results people inspect.

### Query embedding length

The [model-only length grid](query_length_measurements.json) uses the installed
selective-FP16 97M Core ML encoder, all compute units, and 50 warm predictions
per length. Tokenization, index retrieval, and UI are excluded. All runs
reported nominal thermal state and finite outputs.

| Active tokens | Function | Model load | First prediction | Warm p50 | Warm p95 |
| ---: | --- | ---: | ---: | ---: | ---: |
| 8 | query128 | 1038.6 ms | 102.0 ms | 6.37 ms | 7.37 ms |
| 32 | query128 | 173.7 ms | 85.4 ms | 6.82 ms | 8.02 ms |
| 64 | query128 | 174.1 ms | 84.3 ms | 6.05 ms | 8.19 ms |
| 96 | query128 | 174.9 ms | 82.1 ms | 6.69 ms | 8.76 ms |
| 128 | query128 | 172.0 ms | 81.8 ms | 5.86 ms | 8.27 ms |
| 256 | passage512 | 1214.1 ms | 89.7 ms | 10.10 ms | 10.28 ms |
| 512 | passage512 | 173.4 ms | 88.4 ms | 10.10 ms | 10.29 ms |

Function and operating-system caches are not cleared. The first short-function
and long-function loads cost more than later loads, so these are ordered
fresh-process measurements, not seven independent cold-cache samples. The
5.9–6.8 ms medians among short warm inputs do not establish a monotonic token
effect. App startup also initializes model management and tokenization; use
the separate startup report for end-to-end readiness.

### Result-table layout

The [layout aggregate](native_layout_measurements.json) uses identical synthetic
rows at a 1280×720 viewport, six rotated repetitions per result count. It
constructs and lays out the production table offscreen, bypassing the result
cap only in the measurement helper.

| Results | Warm host construction/layout median | Table reload median | Materialized cells |
| ---: | ---: | ---: | ---: |
| 10 | 76.3 ms | 2.87 ms | 8 |
| 20 | 83.5 ms | 2.54 ms | 8 |
| 50 | 80.8 ms | 2.60 ms | 8 |
| 100 | 80.1 ms | 2.80 ms | 8 |

The first-ever host initialization took 165 ms. Virtualization keeps visible
cell work nearly constant. These measurements exclude asynchronous summary
lookup, header work, provider retrieval, model inference, visible presentation,
and display scanout. They do not support a large rendering-speed benefit from
reducing 100 results to 20. The product decision is a fixed maximum of 100
results, with no result-limit setting.

### Production exhaustive search

The [native result-count grid](native_limit_measurements.json) measures all 40
scale/count combinations with separate query tasks and 200 ms idle intervals.
It validates the full requested top K for all 440 queries: strict identity
recall is 100%, with maximum score error 5.36 × 10⁻⁷. All thermal states were
nominal. Timings exclude model inference and UI.

| Scale | Windows | Top 10 | Top 20 | Top 50 | Top 100 | Top-100 final RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1× | 39,066 | 419 ms | 416 ms | 417 ms | 422 ms | 56.9 MiB |
| 2× | 78,132 | 838 ms | 844 ms | 839 ms | 832 ms | 71.5 MiB |
| 3× | 117,198 | 1237 ms | 1245 ms | 1261 ms | 1247 ms | 83.8 MiB |
| 4× | 156,264 | 1673 ms | 1695 ms | 1658 ms | 1654 ms | 95.5 MiB |
| 5× | 195,330 | 2103 ms | 2115 ms | 2106 ms | 2087 ms | 110.8 MiB |
| 6× | 234,396 | 2537 ms | 2539 ms | 2589 ms | 2572 ms | 125.2 MiB |
| 7× | 273,462 | 2942 ms | 2997 ms | 3008 ms | 3011 ms | 132.4 MiB |
| 8× | 312,528 | 3447 ms | 3406 ms | 3423 ms | 3448 ms | 154.4 MiB |
| 9× | 351,594 | 3877 ms | 3849 ms | 3831 ms | 3847 ms | 164.3 MiB |
| 10× | 390,660 | 4283 ms | 4256 ms | 4275 ms | 4262 ms | 172.0 MiB |

These medians include ten warm queries: three perturbed-corpus probes and
one probe from each of seven token-length buckets. The first query is
reported separately in the aggregate. Native length cells contain one
selected query per count, while extension grids use more queries and repeats.

The [initial native run](native_measurements.json) also measures mutations at
every scale. Appending 1,000 windows takes 175–184 ms; deleting them takes
2–29 ms. All ten speaker-boost and deletion/reopen checks passed. Initial
search timings used a continuous task and validated only the top-five score
sets; use the separate-task grid above for the result-count comparison.
Its 10× median was 4.04 seconds; the later grid measured about 4.27 seconds.
These separate runs do not isolate the cause of that difference and should
not be interpreted as a regression caused by the result limit.

The [query-lifetime diagnostic](native_memory_measurements.json) found about 151–157 MiB RSS across three separate 10× query tasks. A continuous task accumulated about 120 MiB per call. The 1.35 GiB batch peak therefore does not represent required full-index residency. Separate-task latency remained about 4.0–4.1 seconds.

A separate 15-second Instruments Time Profiler capture attributed 50.8% of
CPU samples to JSON decoding, 19.7% to source fingerprint validation, 5.3% to
SQLite calls, 0.5% to explicit Accelerate kernels, and 23.0% to other retrieval
work. Inlined scoring may fall in the latter category. These are sampled CPU
shares, not exact wall-time stages. The [profile aggregate](native_profile_measurements.json)
supports reducing per-query metadata decoding and source validation before
attributing the app's full latency to exhaustive vector scoring.

### HNSW precision and scale

The [complete HNSW grid](hnsw_measurements.json) contains all 30 precision/scale
cells, seven candidate counts, direct and FP32-reranked paths, query-length
breakdowns, and mutations. The table uses 1,000 candidates with FP32 reranking.
RSS is the process immediately after graph loading; it includes runtime
overhead and excludes the filesystem cache and embedding model.

| Scale | FP32 RSS | FP16 RSS | INT8 RSS | FP32 rerank | FP16 rerank | INT8 rerank | INT8 speaker-aware | Boosted recall@100 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1× | 115.9 MiB | 87.5 MiB | 73.4 MiB | 12.51 ms | 9.06 ms | 6.06 ms | 7.27 ms | 100.00% |
| 2× | 187.3 MiB | 130.2 MiB | 101.8 MiB | 13.42 ms | 9.83 ms | 6.76 ms | 9.26 ms | 100.00% |
| 3× | 259.7 MiB | 173.5 MiB | 130.9 MiB | 13.40 ms | 10.01 ms | 6.95 ms | 9.96 ms | 100.00% |
| 4× | 330.0 MiB | 215.2 MiB | 157.9 MiB | 13.35 ms | 9.78 ms | 7.09 ms | 11.08 ms | 99.98% |
| 5× | 404.2 MiB | 261.2 MiB | 189.5 MiB | 12.67 ms | 9.83 ms | 7.24 ms | 12.08 ms | 99.98% |
| 6× | 474.8 MiB | 302.9 MiB | 217.2 MiB | 12.51 ms | 9.67 ms | 7.24 ms | 13.07 ms | 99.88% |
| 7× | 544.5 MiB | 343.8 MiB | 243.7 MiB | 12.38 ms | 9.70 ms | 7.12 ms | 14.32 ms | 99.80% |
| 8× | 614.7 MiB | 385.6 MiB | 271.0 MiB | 12.14 ms | 9.50 ms | 7.41 ms | 15.50 ms | 99.70% |
| 9× | 693.0 MiB | 435.9 MiB | 306.6 MiB | 11.86 ms | 9.49 ms | 7.24 ms | 15.67 ms | 99.58% |
| 10× | 763.6 MiB | 477.3 MiB | 334.5 MiB | 11.62 ms | 9.31 ms | 7.19 ms | 16.77 ms | 99.50% |

At 10×, FP32/FP16/INT8 graph files occupy 708.0/408.0/258.0 MB.
The reranking file adds 600.1 MB of original FP32 vectors in this prototype.
INT8 reduces coordinate bytes by 75%, but graph and runtime overhead remain:
measured process RSS falls by about 56% relative to FP32 HNSW. Its fresh-process
graph load takes 115 ms with warm filesystem caches. These figures do not
include a loaded model or the app library.

The speaker-aware path unions 1,000 content candidates with every identified-
speaker window, then scores FP32 vectors and applies the bonus before top-K.
At 10×, INT8 recovers 100% of the boosted top 5, 10, and 20, 99.6% of top 50,
and 99.5% of top 100. It is approximate retrieval, not exact-rank equivalence.
Content-only candidate reranking recovers only 19.4% of the boosted top 100
on that synthetic speaker assignment; overfetching alone is insufficient.

The 10× INT8 candidate-count slice below shows why final result count and
candidate count are separate. All rows use FP32 reranking; recall is against
the content-only exhaustive reference. Full size/length/precision cells are
in the linked aggregate. Search breadth grows with candidate count.

| Candidates | Median | Recall@10 | Recall@20 | Recall@50 | Recall@100 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 0.28 ms | 92.00% | — | — | — |
| 20 | 0.36 ms | 97.17% | 88.42% | — | — |
| 50 | 0.43 ms | 97.67% | 96.58% | 86.43% | — |
| 100 | 0.61 ms | 100.00% | 99.75% | 98.93% | 88.75% |
| 200 | 1.27 ms | 100.00% | 99.83% | 99.47% | 98.92% |
| 800 | 5.57 ms | 100.00% | 99.83% | 99.47% | 99.47% |
| 1000 | 7.19 ms | 100.00% | 99.83% | 99.47% | 99.47% |

| Scale | INT8 append 1,000 + snapshot | INT8 delete 1,000 + snapshot |
| --- | ---: | ---: |
| 1× | 279.3 ms | 39.5 ms |
| 2× | 324.2 ms | 76.9 ms |
| 3× | 363.9 ms | 116.2 ms |
| 4× | 403.0 ms | 196.7 ms |
| 5× | 437.3 ms | 193.8 ms |
| 6× | 479.0 ms | 235.9 ms |
| 7× | 562.3 ms | 287.7 ms |
| 8× | 600.6 ms | 336.2 ms |
| 9× | 642.0 ms | 406.9 ms |
| 10× | 659.8 ms | 415.5 ms |

All 30 lifecycle cells preserve their before/after recall and return no deleted
candidates after reopening. At 10×, INT8 insertion itself takes 246 ms and its
snapshot takes 413 ms; deletion itself takes 0.23 ms and its snapshot takes
415 ms. Full snapshots dominate the saved deletion cost. This tests one churn
batch, not years of repeated graph changes or crash recovery.

Direct INT8 distances should not supply final ranking. On the dense 10×
perturbation fixture, direct compressed top-five identity recall is about
68.7%; unchanged before/after deletion confirms this is not deletion damage.
FP32 candidate reranking and the separate labeled-quality experiment distinguish
compression error, approximate candidate loss, and semantic relevance.

### SQLite exhaustive and DiskANN

The [SQLite grid](diskann_measurements.json) covers every scale. Exhaustive
retrieval requests 100 results; DiskANN retrieves 1,000 candidates and reranks
with FP32 vectors. Speaker union separately uses 200 ANN candidates plus all
identified-speaker windows. RSS below is the final content-retrieval worker;
the speaker-union worker reaches 74.8 MiB at 10×. All times are medians.

| Scale | Exact query | Exact RSS | DiskANN query | DiskANN RSS | Content recall@100 | Speaker union | Boosted recall@100 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1× | 29.63 ms | 49.1 MiB | 61.09 ms | 61.5 MiB | 99.28% | 8.35 ms | 100.00% |
| 2× | 44.22 ms | 49.1 MiB | 61.52 ms | 62.5 MiB | 98.93% | 9.99 ms | 100.00% |
| 3× | 58.75 ms | 49.0 MiB | 61.39 ms | 61.3 MiB | 98.75% | 11.62 ms | 100.00% |
| 4× | 73.24 ms | 50.3 MiB | 60.00 ms | 62.5 MiB | 98.57% | 13.15 ms | 99.98% |
| 5× | 87.37 ms | 50.2 MiB | 58.82 ms | 60.9 MiB | 98.48% | 14.76 ms | 99.98% |
| 6× | 101.95 ms | 50.5 MiB | 57.42 ms | 61.3 MiB | 97.98% | 16.35 ms | 99.87% |
| 7× | 116.36 ms | 48.9 MiB | 56.47 ms | 61.1 MiB | 98.07% | 17.94 ms | 99.78% |
| 8× | 131.15 ms | 49.2 MiB | 55.45 ms | 62.9 MiB | 97.88% | 19.11 ms | 99.73% |
| 9× | 146.43 ms | 48.8 MiB | 54.91 ms | 61.0 MiB | 97.67% | 20.72 ms | 99.62% |
| 10× | 159.42 ms | 50.5 MiB | 54.50 ms | 59.8 MiB | 97.52% | 22.80 ms | 99.60% |

Exact content top-100 agreement is 100% at every scale. Its candidate-grid
speaker boost and eligibility filter apply after content truncation; those
cases are not full-corpus boosted or filtered exhaustive search. The native
app baseline applies the bonus before selection. The speaker-union strategy
is the separate comparison for preserving boosted results.

The table below includes transaction and checkpoint time. Each lifecycle cell
checks append visibility, deletion, replacement, entry-node deletion, and reopen.
No deleted candidates return in the probes. DiskANN's deleted-row point lookup
still raises an error at all ten scales. A successful search after deletion
does not resolve that API failure.

| Scale | Exact append 1,000 | Exact delete 1,000 | DiskANN append 1,000 | DiskANN delete 1,000 |
| --- | ---: | ---: | ---: | ---: |
| 1× | 0.031 s | 0.041 s | 3.280 s | 17.091 s |
| 2× | 0.032 s | 0.080 s | 4.325 s | 32.309 s |
| 3× | 0.029 s | 0.050 s | 5.599 s | 48.190 s |
| 4× | 0.030 s | 0.041 s | 5.674 s | 64.116 s |
| 5× | 0.031 s | 0.040 s | 6.964 s | 80.628 s |
| 6× | 0.031 s | 0.040 s | 9.745 s | 97.512 s |
| 7× | 0.062 s | 0.040 s | 8.837 s | 112.616 s |
| 8× | 0.062 s | 0.042 s | 11.084 s | 128.490 s |
| 9× | 0.070 s | 0.042 s | 11.382 s | 143.808 s |
| 10× | 0.072 s | 0.041 s | 13.741 s | 160.355 s |

At 10×, the DiskANN database occupies 5.81 GB, versus 611 MB for SQLite
exhaustive storage. Cumulative DiskANN construction takes 961 seconds.
The deletion curve is approximately linear over this range. Low process
memory does not compensate for this update cost in a frequently edited library.

### Resource growth and integration choice

[Descriptive fits](growth_measurements.json) use all ten measured sizes,
39,066–390,660 windows. They describe this range and are not extrapolations.

| Engine | Additional process RSS per 100,000 windows | RSS fit R² | Additional graph/index disk per 100,000 windows |
| --- | ---: | ---: | ---: |
| Production exhaustive | 33.56 MiB | 0.9954 | Not fitted |
| HNSW FP32 | 183.96 MiB | 0.9999 | 181.2 MB |
| HNSW FP16 | 110.71 MiB | 0.9998 | 104.4 MB |
| HNSW INT8 | 74.00 MiB | 0.9995 | 66.0 MB |
| SQLite exact | 0.12 MiB | 0.0395 | 156.1 MB |
| SQLite DiskANN | -0.32 MiB | 0.1717 | 1486.6 MB |

SQLite's near-zero RSS slopes and low R² indicate approximately constant
process memory, not a meaningful decrease as the library grows. HNSW graph
figures exclude the separate FP32 reranking file: add 153.6 MB per 100,000
windows on disk. Process RSS excludes the embedding model and OS page cache.

INT8 HNSW with FP32 reranking was selected for app integration.
At 10× it uses 335 MiB RSS, a 258 MB graph, and a 600 MB FP32 disk file.
It retrieves and reranks 1,000 candidates in 7.19 ms; speaker-aware retrieval
takes 16.77 ms and recovers 99.5% of boosted top 100. These are engine timings,
not app response times. Preserve the common provider interface, confirmed
speaker bonus, tag behavior, model-space separation, and cancellation. Measure
SQLite vector lookups and hydrate metadata only for final results. The
[integration worklog](../../docs/worklogs/2026-10-07-hnsw-search.md) records
packed SQLite lookup, snapshot recovery, and provider regression validation.

## Limitations and decision gates

- Approximate candidate truncation can lose speaker-boosted or filtered results,
  even if compressed distances are accurate. Exact speaker union is a candidate
  strategy; it is now implemented in the app, but the benchmark grid does not
  measure the integrated provider’s total response time.
- Native memory depends on query lifetime. The separate-task diagnostic avoids
  the continuous-task accumulation, but neither process includes the full UI
  and loaded embedding model; use the separate app startup measurements for that.
- This grid covers 384 dimensions only. Synthetic scale growth, one graph build
  per configuration, and four text templates per length limit generalization.
- DiskANN's returned-distance and missing-row behavior remain contract failures.
  Metadata filtering, direct updates, and model-space separation require an
  integration design. HNSW journal and snapshot recovery are covered separately
  by integration regression tests, not by this engine grid.
- Concurrent recording/indexing/search, energy use, multiple people, ambiguous
  names, arbitrary person prevalence, and static Swift linking are not measured.
- The app integration uses packed INT8 HNSW with SQLite FP32 reranking. Its
  storage and recovery checks are separate from this grid; standalone engine
  timings do not establish end-to-end application response times.
