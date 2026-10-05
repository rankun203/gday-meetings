---
title: Shared disposable library database
date: 2026-10-05
status: implementation-in-progress
scope: swift-library-storage
---

# Authority and placement

Meeting folders, people and tag documents, and `tasks.jsonl` remain authoritative. `index.db` contains derived library metadata, relationships, full-text passages, directory rows, and task journal offsets. Deleting a stopped app's index loses no source content.

The default local data folder contains its database. Custom folders use the existing local cache keyed by the resolved folder path. This conservative policy includes cloud folders without relying on unreliable cloud-provider detection. Source files and provider embedding artifacts may sync; SQLite, WAL, and SHM files stay local. There is no persistent second-level database.

# Access and schema ownership

`IndexDatabase` owns opening, connection configuration, prepared statements, execution errors, recovery, and schema registration. Domain adapters keep their existing typed query methods. Each serialized adapter uses a separate WAL connection, so a background library rebuild does not hold the task adapter's connection lock. The SQLite writer remains shared. Meeting-folder resolution uses a separate serialized committed-state connection, so a staged rebuild cannot block it or expose unpublished folder mappings. Committed quarantine takes precedence over cached location hints; only unindexed meetings use the cache fallback.

`index_modules` records each module's version and write revision. `index_module_tables` assigns table ownership. Core modules retain their established table names. Additional trusted in-app adapters declare namespaced tables; provider responses cannot submit SQL. Registration rejects invalid identifiers and table ownership collisions. A version mismatch resets that module's derived tables, leaving other modules intact. Version changes that remove tables require an explicit migration review.

Provider adapters write through `Connection.write(module:_:)`, which commits their rows and advances the module revision together. This also covers virtual-only modules, because SQLite does not support ordinary row triggers on virtual tables. Existing core tables have revision triggers so their established savepoint-based query methods participate in the same conflict checks.

The existing library schema version 3 is adopted without replaying source files. Directory and task projections rebuild from their source files when their new shared modules are empty. Earlier separate cache files remain untouched and are no longer opened by the app. Moving a library excludes those obsolete cache files.

# Rebuilds and concurrent writes

Full rebuilds stage rows in connection-local SQLite TEMP tables. SQLite may spill TEMP storage to disk; it is not a second persistent library database. File reads, JSON decoding, and transcript extraction occur before acquiring the shared database writer. Memory use remains bounded by a source document or journal record rather than the entire library.

A completed stage publishes in one transaction. Other connections see the previous committed generation until publication completes. Revision triggers detect a concurrent write to the same module; publication rejects a stale stage instead of overwriting newer indexed work. Writes to another module do not invalidate the stage. Source files remain authoritative after any failure, and the app can rebuild again.

An initially empty meeting index publishes complete meeting rows progressively, preserving first-page availability during its first scan. Rebuilds of a populated meeting index retain the old committed generation. Targeted directory edits parse only changed files, then apply their rows in one transaction; they do not copy the full directory projection.

# Recovery and generated guide

The process-wide owner registry permits corruption quarantine only before the first live connection opens a database. It preserves corrupt database/WAL/SHM files with a unique suffix. Corruption found while another connection is live writes a recovery marker and reports the error; no adapter deletes or renames a live shared database. Reopening after all connections close consumes the marker and permits recovery without a full startup integrity scan.

`index.db.md` lives beside the actual database. A bundled Markdown template supplies the source-authority and placement contract; installed module versions and SQL declarations fill its schema sections. Registration compares generated content and writes only changed guides. It preserves an existing unmarked document or symbolic link. No model calls or source-content scans generate this guide.

# Local voice artifacts and retrieval

Local voice embeddings live inside each meeting folder at `providers/<provider-id>/embeddings/<source-id>/<clip-id>.json`. They move to Trash and restore with the meeting. An explicit removal of a meeting's voice embeddings moves only that owned embedding folder to Trash. The corresponding `provider_clsp` tables are disposable projections in the same `index.db`.

After the app removes a meeting from its library index, background invalidation deletes that meeting's derived vector rows without touching the artifacts in Trash. Restoring the folder and rebuilding imports them again. External folder deletion makes results unavailable immediately through source and meeting checks; an explicit rebuild removes any remaining orphan rows. SQLite row deletion is not a secure-erasure guarantee.

Each bounded artifact records the meeting, audio filename, SHA-256 source revision, clip range, model revision, preprocessing version, vector dimension, normalization, and vector. The current adapter accepts only the pinned CLSP model space. Artifact filenames derive from those identities. Reads reject mismatched identities, nonfinite vectors, unsupported model spaces, and symbolic links.

Building is explicit and runs off the main actor. Audio is hashed once per source, split into ranges of at most 30 seconds, and committed one artifact at a time. A tail shorter than the model's quarter-second minimum uses an overlapping final range. A repeated or resumed build reuses a valid artifact before requesting another embedding. Rebuilding the projection imports artifacts without running the model and hashes each audio source once. Opening the app or registering the module does neither.

Voice queries scan derived vectors with exact cosine similarity, retaining the best clip for each meeting in connection-local TEMP scores. Paging and tag exclusions apply to distinct meetings. The scan decodes one vector at a time; it does not retain the corpus in a Swift array. Current source associations and local file fingerprints reject stale audio or altered artifacts without rehashing audio on every query. Portable artifacts contain no local inode or absolute path; those freshness stamps belong only to the disposable database.

# Technical debt

- Atomic publication copies staged rows into the shared database. Its write transaction grows with module size; it is not a constant-time generation switch. Measure practical fixtures before claiming startup or write-latency targets. If measured publication stalls are material, replace the copy with generation-based publication while preserving FTS row identities and cursor contracts.
- Obsolete directory and task database files remain on disk so migration never deletes a file another app version might have open. A later explicit, stopped-app cache cleanup may remove them.
- The existing people/tag working catalogs and some pickers still load full authoritative catalogs. Consolidating their disposable indexes does not make those consumers bounded.
- Concurrent same-module writes cause a staged rebuild to fail with a retry message. Automatic bounded retry is a future refinement; rejecting stale publication preserves newer indexed state.
- Exact voice retrieval scans every eligible vector and checks artifact freshness. Large-corpus latency has not yet been measured; bounded memory does not imply bounded query time. Measure representative corpora before considering an approximate index. Old source revisions remain as durable artifacts inside the meeting folder, but stale revisions are excluded from retrieval. A future explicit cleanup can retire these revisions without affecting active embeddings.

# Validation

The integrated debug build passed. Storage, search, directory, and task regression suites passed 54 tests; a separate run passed all nine shared-database tests. A synthetic 20,000-metadata-row publication took 58.37 ms, with a maximum concurrent read of 1.41 ms and task write of 61.81 ms. Reads observed only complete generations. An unrelated task write during staging took 0.064 ms. These measurements exclude audio processing and full-text payload volume; they do not establish million-record performance. The complete canonical serial suite passed 914 tests across 160 suites in 129.989 seconds, including stale-cache quarantine and committed reads during staged rebuilding. The canonical production release passed in 221.92 seconds with no warnings using full Xcode (Swift 6.4, SDK 27.0, macOS 26.0 deployment target). Strict signing and the bundled guide template were verified. The final two-file UI cleanup retained those checks: five focused tests passed in 2.936 seconds and its release passed in 170.39 seconds with no warnings.

Evidence: `tmp/search-provider-index-2026-10-05/logs/database-targeted-initial.log` and `database-concurrency-measurement.log`.

The later integrated voice/search/configuration/history batch passed 79 tests across 14 suites. Voice tests cover chunking, short-tail overlap, artifact reuse, folder renaming, exact ranked paging, tag exclusions, stale files, cancellation, model validation, and restoring a meeting after rows-only invalidation. Worker tests verify persistent request framing, cancellation, recovery, and a distinct timeout error. These are synthetic regressions with an injected embedding worker; they do not measure model retrieval quality. Evidence: `tmp/search-provider-index-2026-10-05/logs/voice-final-nonhosted-tests.log`.
