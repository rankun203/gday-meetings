---
title: Shared index and search providers
date: 2026-10-05
status: in-progress
scope: swift-storage-and-search
---

# Problem

Library, directory, and task indexes had independent SQLite lifecycles and recovery rules. Search bypassed provider capabilities and returned only lexical matches. Descriptions of speech delivery or audio content need a different representation from transcript text and speaker identity embeddings.

# Implemented solution

- `IndexDatabase` owns connections, prepared statements, execution errors, schema registration, and recovery for one `index.db`. Library, directory, task, and CLSP adapters use independently versioned modules. Background rebuilds stage rows in TEMP tables, then publish atomically; module revisions reject stale publication after a concurrent write. Trusted in-app providers may register namespaced tables. Remote responses cannot supply SQL.
- A bundled Markdown template generates `index.db.md` beside the actual database and refreshes it when registered schema changes. It documents installed tables, indexes, and triggers without model calls or scanning source content. Meeting folders, people/tag documents, `tasks.jsonl`, and portable embedding JSON remain authoritative.
- The maintainer confirmed that SQLite stays local for cloud folders. Existing custom-folder caches remain local conservatively; source files and embeddings may sync. No persistent `index-l2.db` was added.
- Local text search now uses the streaming provider contract. Ranked text pages retain the best evidence per meeting. Provider snapshots replace prior contributions; reciprocal rank fusion combines distinct meeting ranks without multiplying repeated streaming events. Failed channels remain visible, and Fusion requires text and voice providers.
- Local voice search uses the optional Python CLSP worker after explicit preparation. Model weights are not loaded at startup. Explicit builds hash each audio source, save bounded clip embeddings inside its meeting folder, and reuse valid artifacts on subsequent builds. A short tail uses an overlapping valid model window. Model-free rebuilding restores derived rows from artifacts.
- Exact cosine retrieval checks the pinned model space, source association, and file freshness. It scans one vector at a time and pages the best clip per meeting. Opening a result does not start playback; Play Match uses its typed audio range. Provider configuration and Text, Voice, and Fusion controls use the actual adapters.
- File monitoring resolves nested provider-artifact events to their owning meeting folder. Deep embedding directories and loose files are not treated as newly dropped meeting folders.
- Embeddings follow meeting folders into Trash and back. App deletion separately invalidates derived vector rows off the main thread. External deletion hides results through source checks; rebuilding removes orphan rows. SQLite row deletion is not a secure-erasure guarantee.
- Worker transport uses bounded newline framing with POSIX pipe reads. Cancellation, timeout, and malformed responses have distinct handling. Recording start cancels indexing, and active indexing blocks library relocation. The quit hook explicitly shuts down owned workers, including a bounded termination fallback, and invalidates pending preparation. Cancellation can resume with a fresh provider if quitting is aborted.

Storage contracts are in `docs/design/2026-10-05-shared-library-database.md`. Model selection and licensing research are in `docs/design/2026-10-05-audio-search-research.md`. Window chrome, tabs, and speaker appearance remain tracked in the native-window worklog.

# Reasoning

One database owner prevents conflicting database-wide versions and unsafe whole-file recovery while allowing independent readers. Durable folder artifacts make database loss recoverable and preserve Trash/restore behavior. Exact vector scanning establishes a measurable baseline before adding another index format or approximate retrieval.

Audio descriptions are approximate retrieval cues. They do not establish age, gender identity, employment role, or a person's identity. Roles come from supplied metadata; inferred personal attributes are not saved as confirmed People records. Entity-aware retrieval is a separate research proposal: named-person queries must use actual library relationships rather than substitute a similar voice. A reusable maintainer-trained model may be considered there; users should not need to train on their libraries.

# Validation

Complete serial validation exposed two folder-recovery issues. Pre-transaction search parsing consulted a quarantined identity after reconciliation had verified one remaining folder; it now reads that validated folder directly. A concurrent positive location-cache refresh could also hide quarantine. Resolution now checks committed index state first through a separate reader, and staged rows do not update the global location cache. All **23 focused database, consistency, and folder-guard tests pass**, including deterministic stale-cache and 500-row staged-read regressions. The corrected full serial suite passed **914 tests across 160 suites in 129.989 seconds**.

- The latest nonhosted Swift run passed **79 tests across 14 suites in 5.010 seconds**, covering storage, search, provider configuration, worker timeout/cancellation, recording cancellation, artifact reuse, folder renaming, and meeting restore. The relocation regression first exposed inconsistent copy/manifest exclusions; all **five folder-choice tests** pass with the shared predicate. A later **23-test hosted/lifecycle/worker run passed in 5.249 seconds**, including the indexing gate, native navigation, quit cancellation, and a synthetic worker that ignores SIGTERM. Active and queued requests stop, and a shut-down client cannot launch another process.
- A synthetic **20,000-row metadata publication took 58.37 ms**. Maximum concurrent task-write delay was **61.81 ms**, and maximum concurrent read time was **1.41 ms**; readers observed complete generations. This fixture excludes full-text payload volume and model work. Publication time is proportional to copied rows, not constant.
- The local Python worker's **three tests pass in 0.01 seconds** using `uv run --project apps/worker-search --group dev pytest apps/worker-search/tests -q`.
- A three-clip synthetic CPU model smoke test took **19.44 seconds** at **3.20 GB peak resident memory**. Within one voice it ranked delivery speeds as expected; another voice ranked first for both descriptions. Cross-speaker retrieval quality remains unresolved.
- In isolated Preview, native path selection, Save, readiness, and provider selection passed. The actual local worker indexed **six clips across two synthetic meetings**. Voice returned two timestamped results. Open preserved stopped playback; Play Match selected the correct track at **0:30**. Fusion returned a transcript match and an audio-only candidate. This proves integration with a tiny synthetic corpus, not retrieval quality.
- Final local review covered shared database ownership/recovery, publication, folder quarantine, authoritative artifacts, ranking, and worker/controller teardown. A read-only process check after test and Preview teardown found no local search worker processes. No real library was launched.
- Generated `index.db.md` included the library, directory, task, and CLSP schemas. Six portable artifacts remained in meeting folders after Preview quit. The synthetic library was preserved; no real library was used.
- Automatic approval review rejected the additional Claude source audit before launch because prior external-disclosure authorization covered header advice, not database/search source. No source was sent and no workaround was attempted. Local review and regression validation continued. The exact limit and findings are recorded in `tmp/native-window-polish-2026-10-05/audits/shared-db-search-review.md`.

Evidence is under `tmp/search-provider-index-2026-10-05/logs/` and `tmp/native-window-polish-2026-10-05/search/`. The full serial suite passes. The canonical production release passed `make build-macos` in **221.92 seconds**, with **zero warnings**, macOS 26.0 minimum, and SDK 27.0. Strict signing and the bundled schema template were verified. The previous candidate was moved to Trash; the replacement is `tmp/native-window-polish-2026-10-05/production/Gday Meetings.app` and was not launched against the real library. Final chrome validation remains separate.

# Technical debt

- Atomic publication copies staged rows under a writer lock. Measure larger transcript/vector projections before choosing generation-based publication or independently opened L2 storage.
- Exact voice retrieval has linear scan and file-check costs. Large-library throughput, real-world retrieval quality, and native model conversion remain unvalidated. Old embedding revisions stay as durable artifacts but are excluded from retrieval; a future explicit cleanup can retire them.
- Obsolete separate database files remain untouched to avoid removing files another app version could have open. A later stopped-app cleanup can move them to Trash. Existing full people/tag editing catalogs and some pickers remain unbounded consumers despite paged directory views.
- Four deprecated AMP decorators in the pinned third-party CLSP model remain visible. Obtain an upstream fix or review a reproducible patch before distribution; do not silently alter cached model code.
- Earlier debug/test linking reported missing CommandLineTools library/framework search paths. Using `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` removes those warnings without changing global tool selection; both installations report Swift 6.4 and SDK 27.0. The canonical debug build passed in 69.12 seconds and the release in 221.92 seconds, both with no warnings.
