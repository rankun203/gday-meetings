---
title: Packed INT8 HNSW search integration
date: 2026-10-07
status: complete
scope: macos-search-storage
---

# Problem

The app scanned all FP32 vectors and metadata, while portable embedding artifacts
stored numeric coordinates in JSON. The benchmark favored INT8 HNSW retrieval
with original FP32 reranking.

# Implemented solution

Pinned USearch 2.26.4 and NumKong 7.8.5; implemented packed INT8 and
little-endian FP32 coordinates in portable binary artifacts and per-window
SQLite blobs. Retrieval takes 1,000 eligible HNSW candidates, unions confirmed-speaker
windows, reranks using original FP32 vectors, and hydrates the final 100 results.
Meeting updates retain stable graph keys and journal only added, removed, or
changed INT8 coordinates; metadata and speaker changes do not reinsert vectors.
Temporary Foundation allocations are bounded per indexing transaction and query.

# Reasoning

SQLite remains a disposable projection of meeting artifacts. The HNSW snapshot
is also disposable. SQLite commits vector changes and an ordered journal together;
the resident graph applies them after commit. Snapshots carry their applied sequence,
and restart replays later changes idempotently. Invalid snapshots rebuild from packed
INT8 rows. Checkpoints span meetings: 10,000 changes or 30 seconds, an idle timer,
and unload. This avoids serializing the entire graph for every meeting. Publish the
snapshot and receipt before advancing SQLite’s checkpoint and pruning the journal.
Native graph access is serialized by the search actor. Exclusions participate
in candidate retrieval rather than consuming the candidate budget.

# Technical debt

No old-format reader or dual writer is introduced. A separate, stopped-app
converter retains a backup of development JSON artifacts. The existing meeting-scoped
index task UI remains a separate compromise: a library rebuild still creates many
tasks. This change is limited to storage and retrieval. Apply the
[batch-task design](../design/2026-10-06-search-index-tasks.md) to consolidate
those tasks and their progress display.

USearch retains removed slots for later insertion. This keeps updates inexpensive,
but a large deletion does not promise an immediate RAM reduction. A rebuild
compacts from live SQLite rows. A future maintenance policy can trigger that
rebuild from measured deletion/retained-capacity ratios; no automatic compaction
threshold is introduced without a workload measurement.

# Validation

All 53 focused release tests passed, covering packed storage, native quantization,
speaker union before top-100 selection, tag exclusions, incremental append and
metadata updates, replacement/deletion, cancellation, checkpoint batching,
idempotent replay, external-writer recovery, corrupt snapshots, both model
spaces, temporary path aliases, and escaping cache symlinks. Six Python migration
tests pass. Swift formatting, lint, Python lint, and whitespace checks pass.
`make build-macos` passed in the isolated checkout in 186 seconds. The packaged
app targets macOS 26, uses SDK 27, and passed signing verification. It is retained
under ignored `tmp/local-search-hnsw-2026-10-07/` for later installation.
The installed app was not replaced. The build retains existing CLT linker warnings
about missing Developer framework/library search directories; it reported no
deprecation warnings. No UI code changed, so validation used production providers
and native release tests rather than a new visual preview.

The full opt-in Core ML conversion-probe suite was not rerun. Model assets and
inference code are unchanged; the copied-library provider run exercised model
loading and passage tokenization. This work does not remeasure complete app
startup, query embedding latency, or UI response time. Performance measurements use
384 coordinates; 768-coordinate storage and model isolation have regression
coverage, but the 311M model has no new recall or scaling grid in this integration.

# Build integration

The upstream SwiftPM graph compiled but failed to link because Swift Build
requested an object file for NumKong's header-only C target. The alternative
native backend is deprecated in Swift 6.4 and was rejected. Following the
repository's native-audio pattern, unchanged source archives are checksum-pinned
and compiled with CLT into a static library. No dummy object, generated-checkout
patch, or deprecated build flag is used. Native dispatch is enabled and license
notices ship in the app. An initial NumKong 7.5.0 probe selected scalar INT8
kernels on M1 Max: it gated signed dot products on `FEAT_I8MM`, which this CPU
does not report. The supported 7.8.5 release uses `FEAT_DotProd`; the native probe
and integrated test now select `neonsdot`. No capability is forced.
Updating dependencies requires replacing the archives,
checksums, copied public C header, and validating quantization and retrieval.

# Migration

Run `uv run --no-project apps/client-macos-swift/scripts/pack-search-artifacts.py
--library LIBRARY` to inspect existing artifacts. After quitting apps that use the real library, add `--apply --backup BACKUP_OUTSIDE_LIBRARY`. The script validates
normalized vectors, packs both precisions, verifies the binary plist, and retains
the original JSON in the backup before removal. The v3 disposable projection is
rebuilt from packed artifacts. Model identity is unchanged; no inference is
needed for unchanged passages. Applications using the old projection must stay
closed during the format switch. Verified `GdayUIPreview` bundles always create
temporary libraries and may remain open.

The converter was initially applied to 365 artifacts containing 39,326 windows.
Their coordinate payloads total 60,404,736 FP32 bytes and 15,101,184 INT8 bytes;
metadata is additional. The user then requested continued use of the old app.
All 365 original JSON artifacts were restored with atomic no-overwrite publication,
and only unchanged conversion outputs were removed. The live search database was
never migrated. Verified originals remain under ignored
`tmp/search-packed-backup-2026-10-07/`; they are recovery copies, not inputs for
replacing newer user data.

Subsequent validation uses a private temporary clone, with SQLite's backup API
for a consistent database snapshot. `--isolated-copy` permits migration only below
a temporary directory while the app continues using its original library. The
copy contains 366 artifacts because the live library continued changing. Final
live-library migration is deferred at the user's request: quit the app, take a
fresh backup, convert current artifacts, and rebuild with the new provider. Do not
reuse this validation copy to overwrite newer user data.

Swift decoded and validated the Python-generated synthetic format fixture.
The frozen benchmark contains 39,066 windows; do not treat the newer library
snapshot as the same dataset.

# Integrated measurements

On M1 Max, the frozen 39,066-window fixture built in 13.70 seconds without model
inference. Its 12 integrated retrieval probes took 140–164 ms, including source
validation, SQLite FP32 reranking, and 100 hydrated results. The native HNSW stage
alone took 3.0–5.3 ms. Reloading the snapshot in the same process took 23.5 ms;
the OS file cache was warm. This is not cold app startup or model loading.

The private library copy rebuilt 366 meetings / 39,327 windows through
`SemanticSearchProvider.updateIndex` in 86.60 seconds, including content loading,
tokenization, and reuse of saved embeddings. Its 12 existing-passage vector probes
returned 100 results each in 63.7–123.2 ms. Snapshot reload took 23.5 ms. These
probes validate the retrieval path with copied real metadata, but are not a new
human-labeled relevance evaluation and exclude query embedding and UI rendering.

A separate process loaded the existing copied index without constructing fixtures
or loading an embedding model. RSS started at 32.0 MiB, reached 67.1 MiB after
loading, and 84.5 MiB after 12 searches; final physical footprint was 55.5 MiB.
The graph/load increment was 35.1 MiB. Process RSS includes framework and allocator
pages; it is not a vector-payload measurement or a full-app resource measurement.

That process loaded the graph in 26.6 ms. Its first retrieval took 276.0 ms;
the following 11 had a 173.2 ms median (156.4–219.6 ms). These probes use frozen
vectors against the newer copied library, with real metadata and source checks,
so they differ from the existing-passage probes above. OS caches were not flushed.
Query embedding, model loading, and UI rendering remain outside the interval.

These integration latency probes contain no identified People. Speaker-union
correctness has regression coverage and earlier engine benchmarks, but large
speaker unions are not timed in the integrated provider here.

The disposable validation clone and its conversion backup were removed after
testing. The recovery backup and final signed app remain available.
