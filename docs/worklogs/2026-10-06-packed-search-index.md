---
title: Packed vectors for local search
date: 2026-10-06
status: validated
scope: macos-search-storage
---

# Problem

After deploying the optimized 97M model, a release-code check indexed 366 authorized meetings without failures, but 16 searches took a median 4,360 ms. Query embedding alone took roughly 6 ms in the separate model benchmark. The existing exact search decoded JSON coordinates, validated each vector, and created and sorted a result object for every passage.

# Implemented solution

The semantic SQLite module now stores little-endian FP32 vector BLOBs separately from passage metadata. Accelerate calculates dot products and norms directly from each meeting's SQLite buffer. The scan keeps bounded top results and constructs result objects only for candidates that enter that set. Speaker bonuses still apply before selecting results, and source fingerprints, excluded tags, model spaces, cancellation, and deterministic tie ordering remain part of the search path.

Schema version 2 rebuilds only the disposable semantic projection. Per-meeting provider artifacts retain their existing format, so the projection can reuse previously calculated embeddings without running inference again. The model-space identifier stays unchanged because the embedding model and window construction are unchanged.

# Reasoning

Remove the measured serialization cost before selecting an approximate backend. This scan keeps only one meeting's vectors in scope and introduces no full-library graph or vector cache. FP32 matches the model output precision; differences from the previous Double accumulation require ranking comparison. The exact scan is also the reference for future speaker-aware ANN recall tests.

The scale worklog's HNSW memory concern remains applicable. SQLite-vec's [0.1.10-alpha.4 release](https://github.com/asg017/sqlite-vec/releases/tag/v0.1.10-alpha.4) includes DiskANN, but is a prerelease. [LibSQL vector search](https://docs.turso.tech/features/ai-and-embeddings) offers another disk-oriented index through a different SQLite engine. Neither is selected without memory, disk-I/O, recall, and lifecycle measurements. Keep index implementation behind the storage boundary.

# Technical debt

The exact scan remains linear in library size. This is accepted as the measured native baseline, not a solution for millions of windows; evaluate DiskANN and other candidates against its boosted rankings before choosing an approximate backend. JSON provider artifacts remain a second on-disk representation to support incremental reuse and rebuilding. A future versioned binary artifact format can reduce that retained disk overhead without coupling provider artifacts to a database extension.

# Validation

Ten tests across three suites passed, including the authorized real-library check. All 366 meetings indexed without failures. The 16 queries kept identical ordered top-five results, with a maximum score difference of 0.0000001283. Median complete search fell from 4,360.44 ms to 416.33 ms (range 407.82–433.21 ms). The new projection has 39,066 windows, 60,005,376 bytes of vectors, and 23,315,099 bytes of metadata, excluding SQLite overhead. Rebuilding through the incremental provider path took 83.51 seconds. These are warmed-model, single-pass measurements, not controlled cold-cache or resident-memory measurements. The final isolated `make build-macos` passed in 95.47 seconds after the focus follow-up; the staged signature verified. The existing Command Line Tools linker warnings about missing Developer library/framework search paths remain. Formatting, lint, and whitespace checks passed. The updated app returned real-data semantic results; Open selected a transcript passage and Back restored the search. The final screenshot confirmed the compact layout. No commit or push was made; CI was not run. Tests cover reopening, score tolerance, speaker boost before top-K, source changes, replacements, removals across connections, and separation between model spaces. Private queries, meeting identities, excerpts, and receipts stay ignored.

## Timing boundaries and storage interpretation

The first full embedding pass took **571.885 seconds (9 minutes 32 seconds)** for
366 meetings and 39,066 windows, including model preparation, with no failures.
The later **83.505-second** projection rebuild reused saved embeddings; it is
not a fresh embedding throughput measurement.

Packed FP32 means contiguous little-endian binary coordinates, four bytes each,
rather than JSON decimal strings decoded into Double values on every search.
A 384-coordinate embedding takes 1,536 bytes. The complete vector payload is
60,005,376 bytes (60.0 MB; 57.2 MiB), or 600,053,760 bytes at ten times the window
count. This is an on-disk payload, not a permanently resident array. The app scans
one meeting's vector buffer at a time and requests a 2 MiB SQLite page cache per
connection. Operating-system caching and other process allocations mean payload
size alone cannot predict resident memory. Stored FP32 coordinates are separate
from the embedding model's mixed FP16/FP32 inference precision.

| Measurement | Recorded result | Boundary |
| --- | --- | --- |
| First query after indexing | 433.208 ms | Model already prepared |
| Next 15 queries | Median 416.110 ms; range 407.823–419.805 ms | One sequential pass |
| All 16 packed searches | Median 416.333 ms | Complete provider search, excluding UI rendering |
| All 16 previous JSON searches | Median 4,360.437 ms | Same queries and ordered top-five comparison |
| App launch to visible window | 712–1,004 ms | Two fresh processes; native layout, not display scan-out |
| App launch to search ready | 3,386–3,552 ms | Automatic preparation; measurement-only task scheduler disabled |
| Index open separately | 1.216–2.147 ms | Connection/schema initialization; no eager full-vector load |

The search measurements include tokenization, embedding, source validation,
metadata decoding, and exact retrieval. They use a limit of five with no
identified people or speaker bonus. Filesystem caches were not controlled.
Separate single-function model probes measured 97M model load at a median
121.857 ms (range 120.532–1,201.430 ms), first prediction at 83.953 ms, and warm
prediction at 6.296 ms. Corresponding 311M values were 215.649 ms
(range 214.685–222.408 ms), 127.241 ms, and 9.504 ms. Those probes do not measure
the app's multifunction model startup or a fresh operating-system cache.
The dedicated app measurements below are complete; the DiskANN scale comparison is complete.

## Fresh-process app measurements

Two isolated release launches against the authorized 366-meeting library reached
a visible, laid-out window in **0.712–1.004 seconds** and search-ready in
**3.386–3.552 seconds**. Filesystem and Core ML caches were not cleared; these
are fresh-process measurements, not cold-boot guarantees. Task execution,
resumption, recovery, and external task-journal reload were disabled only in the
measurement copy to isolate search and avoid competing journal writers. Production
behavior is unchanged. Detailed method and limits are in the
[startup worklog](2026-10-06-search-startup.md); aggregate receipts are in
`experiments/embedding-optimization/startup-measurements.json`.

| Preparation stage | Two-run range |
| --- | ---: |
| SQLite open/schema initialization | 1.216–2.147 ms |
| Complete model preparation | 2,502–2,621 ms |
| Model acquisition, including manager checks | 839–850 ms |
| Tokenizer construction | 1,576–1,673 ms |
| First warmup prediction | 86.6–96.8 ms |

The first submitted search took **675.5 and 697.5 ms**. The next eight searches
had a pooled median of **489.8 ms**, with a **458.1–538.1 ms** range. The boundary
is query submission through native result layout, including name matching,
tokenization, inference, exact retrieval, and UI work. These UI searches request
100 results, unlike the earlier top-five provider harness. Do not interpret the
difference from 416 ms as a controlled performance regression.

Whole-app peak RSS at search-ready was **919–933 MiB**, increasing to
**972–1,030 MiB** after queries. These totals include the app, UI/library objects,
model, tokenizer, and runtime allocations; they are not index-only memory.
Thermal state was nominal in both runs. Index initialization is inexpensive
because vectors are streamed during queries rather than loaded as one resident
array. Tokenizer construction is a larger startup cost than warm inference and
is a concrete target for profiling and caching work.

An earlier unisolated launch reached its window at 1.784 seconds and search-ready
at 7.489 seconds. Its first search took 739.6 ms; the next four took 444.9–472.4 ms.
That launch resumed existing search-index tasks and encountered external journal
changes. It is retained as an observational result, not pooled with clean runs.
Only search-index tasks were observed among the recent task records. The
measurement app was quit before clean tests; task journal contention and the
user-reported rebuild behavior are addressed in the
[task behavior proposal](../design/2026-10-06-search-index-tasks.md).


## Scale and profiler follow-up

The [384-dimensional scale experiment](../../experiments/search-index-scale/RESULTS.md)
now measures unchanged production retrieval at every size from 39,066 to
390,660 windows. The initial warm top-five latency grows from 416 ms to
4,043 ms. The subsequent 40-cell result-count grid measures 10, 20, 50, and
100 results at every scale: all 440 full top-K sets match the exact reference.
At 10×, all four limits take 4.26–4.28 seconds with separate query tasks;
reducing the result limit does not remove the scan cost. The product uses
a fixed maximum of 100 results with no slider. Appending 1,000 windows through ten production meeting
transactions takes 178 ms at 10×; removing those meetings takes 29 ms. All
score-reference, boost-before-top-selection, and deletion/reopen checks pass.
These measurements exclude model inference and UI.

The initial three-query diagnostic at 10× remains around 151–157 MiB RSS;
the longer result-count grid reports 172–179 MiB. Both exclude the operating
system's filesystem cache, which can retain SQLite pages. The continuous
benchmark task's 1.35 GiB peak was sensitive to autorelease lifetime and is
not required vector residency. The harness uses frozen vectors and equivalent
metadata reconstructed after the live library changed; it does not claim
original semantic pairing between those two inputs.

A 15-second Instruments Time Profiler capture attributes about 50.8% of CPU
samples to JSON decoding and 19.7% to source fingerprint validation. Explicit
Accelerate kernels account for 0.5%, with inlined scoring potentially included
in other retrieval work. This supports scoring compact index data before
loading detailed result metadata, while preserving freshness checks through
an explicit invalidation design. No production optimization or index backend
change was made by this follow-up. HNSW precision and DiskANN update grids
are complete in the linked experiment. INT8 HNSW with disk-backed FP32 reranking is the preferred next prototype; the app backend is unchanged.
