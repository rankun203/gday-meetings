---
title: File-authoritative meeting library and disposable index
date: 2026-09-27
status: implemented
scope: swift-storage-and-transcripts
---

# Contract

Human-readable files are authoritative. Agents can read, search, and edit them with normal filesystem tools. `index.db` is a disposable SQLite index for speed. Removing it must not lose meetings, people, tags, relationships, or tasks. Rebuild from files without requiring a previous database. Do not maintain a second authoritative database representation.

Before 1.0, format changes use a temporary, verified migration script. Do not ship old-format readers, automatic legacy migration, or dual writes. Preserve a backup of development data and switch only while its app is stopped. The user launches the new production app after migration.

# Layout

```text
com.gdaymeetings.macos/
  index.db
  index.db.md
  settings.json
  meetings/YYYYMMDD_<base36-id>/
    metadata.json
    content.json
    transcript.jsonl
    transcript-checkpoint.json  # live committed boundary and recent rows
    summary.md
    notes.md
    audio and attachments
  people/<id>.json
  tags/<id>.json
  tasks.jsonl
  providers/<provider-key>/
    models.json
    languages.json
    search-log.jsonl
```

Metadata contains only list fields and relationships; transcript, summary, notes, and other content stay separate. People and tags have stable IDs independent of display names. Meeting metadata stores person/tag IDs; reverse relationships are derived in the index. Task state remains in the task journal, not only index.db. Provider credentials retain existing secure storage.

Search evaluation events append to one `providers/<provider UUID>/search-log.jsonl` file per provider. These are authoritative history, not disposable index data. Schema version 1 links submission, execution, displayed-snapshot, and interaction IDs. Events preserve query and filter settings, model and algorithm versions, source revisions, ordered retrieval candidates and final results, elapsed timings, and implicit relevance signals. Logs contain result excerpts and audio locations, without audio bytes or embedding vectors. They have no automatic retention limit and survive index rebuilds and metadata-cache cleanup. Readers must skip malformed lines from interrupted appends. See the [search log worklog](../worklogs/2026-10-08-search-evaluation-log.md) for event semantics and validation limits.

Meeting IDs use lowercase base36. New meeting folder names prepend the meeting’s local Gregorian date as `YYYYMMDD_`; the prefix is only a label. Existing plain-ID folders stay in place, and changing a saved meeting date does not rename its folder. The disposable index records actual folder names for direct lookup. New meetings allocate monotonic Unix-nanosecond values, preserving the Rust ID appearance, with collision/clock rollback handling. Internal UUID-shaped references can encode the same integer without leaking verbose folder names. All meeting folders are direct children of meetings/, as requested after reviewing the hash buckets. Paths are resolved centrally. Existing development meeting IDs are converted by the temporary script along with references.

# Index and paging

Index metadata and relationship tables with `(created_at DESC, id ASC)` ordering. A stored negative creation timestamp allows a single ascending tuple range seek. Request 20 records with a cursor derived from the last record, not increasing OFFSET. Tag/person filters use reverse relationship indexes. Startup queries the first page immediately when the index exists; it does not parse every meeting folder. Hydrate only selected/needed content, with bounded caches and active-operation pinning. Infinite scrolling must not accumulate complete transcript payloads.

Index updates follow durable file writes. A crash after a file update but before indexing is repaired by reconciliation. A rebuild uses a separate connection to the same WAL database. When an index already contains records, a transaction retains its previous committed view for readers until the rebuilt view commits. An initially empty index commits every 500 records so the first page can appear while indexing continues. A completion marker distinguishes a complete index from an interrupted initial build. Filesystem events queued during rebuilding are reconciled afterward. Corrupt index recovery must never rewrite source documents.

A missing-file meeting load requests a separate **Updating Index** background task. Recheck the resolved folder and library availability before removing a stale row; preserve source files, renamed meetings, and unavailable or transaction-protected libraries. Refresh the catalog after removal instead of leaving a persistent missing-meeting error.

An index is not a backup. File backups preserve authoritative documents and assets. Malformed source JSON is reported without replacing it with defaults. Entity deletions, multi-file publication, and concurrent agent/app edits need explicit revision checks and atomic file replacement; stale app state must not silently overwrite external edits.

# Monitoring and folder discovery

Watch the full data root with one FSEvents stream. Exclude database/WAL/temp index files, caches, and owned staging artifacts. Coalesce changed paths and reconcile affected entities on a bounded background queue. Persist the event position only after corresponding changes are indexed. Launch/wake catch up from that position; dropped events or unavailable history trigger a background reconciliation. Do not register one watcher per meeting or poll all meeting directories each second.

For a dropped meeting folder:

1. Wait for copy activity to settle using size/mtime stability checks; retry incomplete media. Settling is a heuristic, not proof a Finder copy is complete.
2. Preserve valid unused base36 folder IDs; otherwise allocate an ID and normalize the folder name without overwriting another folder. Preserve the original name as a title.
3. If supported audio exists and metadata.json is absent, generate minimal metadata: identity, title, creation date, language/defaults, and audio filenames. Determine duration asynchronously. Missing transcript/summary is normal.
4. Never replace malformed existing metadata. Show a repairable error.
5. Add the index row and notify the list. Folder discovery does not automatically upload or transcribe audio.

Agents can make imports deterministic by preparing a folder outside the watched root and atomically moving it into meetings/. Subsequent files or edits reconcile the same meeting. Symlinks must not allow traversal or writes outside the library.

At millions of records, ordinary work is proportional to changed paths or requested pages. Full rebuilds necessarily read every metadata file and can take substantial time; they must be cancellable/resumable or clearly report a restart and remain memory bounded. Exact global counts come from the index, not repeated directory walks. Do not claim million-record performance without measurements.

# Data settings

Add a Data tab alongside existing settings tabs. Capture the current settings screen before changing it. Use native grouped rows:

- Data Folder: selectable path and Show in Finder.
- Index: formatted size and Rebuild Index in the same row; disable duplicate rebuild requests.
- While building: phase, records processed, and progress; use indeterminate progress when the total is unknown.
- Meetings, People, Tags, Tasks counts; mark incomplete counts during initial indexing.
- Inline error with an actionable retry when indexing fails.

No duplicate explanations or claims that an index is a backup. Compare the implemented screen with the design in Preview and the full app.

# Transcript scrolling

Preserve the screenshot's timestamp/speaker/wrapped-text columns and fixed transcript actions. Remove filesystem work from row construction, linear segment searches from bindings, and permanently active multiline editors. Use reusable native table rows with one active editor, stable identities, cached text heights, and targeted change publication. Single-click a row to play from it; double-click transcript text to edit or a speaker badge to choose a person. Display rows show a subtle hover highlight. Text selection is available while editing. Keep the title header compact with a small play control. Editor activation, save/cancel, keyboard navigation, seeking, and accessibility must remain usable.

ProMotion is a measurement target: about 8.3 ms per frame at 120 Hz, not an animation toggle. Validate on real display hardware and report hitches/limits candidly.

# Validation and benchmark plan

Use separate development benchmark libraries, never duplicate inside the user's normal library. Create 1,000 copies of a synthetic long meeting and 100,000 copies of a synthetic short meeting. Copies need unique identities and consistent metadata references. Use independent APFS copy-on-write clones for large immutable media where available; document this so disk usage and cold media-read results are not misleading. Do not create hard links for mutable documents. Never enable automatic provider work in benchmark settings.

Launch the packaged full app against these libraries using GDAY_SWIFT_DATA_DIR, not UI Preview or a test host. Measure indexing duration, first-page availability, startup/idle CPU, RSS/peak memory, and page navigation. Distinguish initial rebuild and warm-index launch. Exercise folder discovery, agent file edits, index deletion/rebuild, malformed metadata, restart recovery, and paging beyond 20 records. Ask the user to test real scrolling after handing off the full benchmark app. No fabricated 120 Hz claim from screenshots.

# References

- [SQLite cursor paging](https://www.sqlite.org/rowvalue.html).
- [Apple FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/Introduction/Introduction.html).
- [AppKit responsive scrolling](https://developer.apple.com/documentation/appkit/nsview/iscompatiblewithresponsivescrolling?language=objc).

# Technical debt

Implementation and measured limitations are recorded in the associated worklogs. A one-million-meeting target is not an achieved benchmark; the requested full-app runs cover 1,000 and 100,000 copies. Task journal replay and people/tag consumers must be audited separately from meeting pagination; an indexed Meetings screen alone does not establish bounded memory for all entity types.

# Task history and execution

`tasks.jsonl` remains authoritative. The task module in the shared `index.db` stores each task's latest event offset, length, digest, identity, creation time, state, meeting, kind, and scheduler priority. It contains no copied task payloads. The database stays in the local `indexDirectory`, outside a custom or cloud-backed data folder. Deleting a stopped app's index loses no task history. The [shared database contract](2026-10-05-shared-library-database.md) covers module versions, staged rebuilds, recovery, and the generated schema guide.

A cold rebuild streams committed events into a SQLite transaction with bounded memory. It validates the source revision before and after replay; only an incomplete final line may be removed before a later append. A warm open reuses the index when the file size, modification time, and identity still match. Page reads verify indexed event identities and digests. A damaged disposable index is rebuilt from the source; malformed committed source events block writes and leave the journal unchanged.

History queries seek by immutable creation time and task ID, in either direction. The Tasks view requests 50 records and retains at most 150 rows, independently of selection. The operational cache retains 100 nonrunning task payloads plus running tasks; synthetic Preview records are separate. The scheduler queries only enough queued records to fill its execution slots. Recovery processes 50 records per batch and yields between batches. Counts come from indexed state totals and update after durable transitions.

Intent, provider-request binding, restart, dismissal, and terminal state changes still append and synchronize before dependent operations proceed. Progress text is transient presentation state: changing it does not append an event. The next durable transition includes the current progress text. Completion receipts remain the authority for reconciling saved results after interruption.

External changes are compared against previous indexed event offsets and digests, rather than against the bounded UI cache. Changed active records require explicit continuation. An orphaned running record completes when its meeting has a matching completion receipt; otherwise it requires attention. An unrelated external append does not change untouched queued records.

Voice-library startup loads metadata, file revisions, and saved preparation jobs on one shared utility worker after the first visible window update. Interrupted running and queued jobs are checkpointed as paused before publication. Voice mutations await readiness; meeting navigation can proceed while loading and receives saved decision projections afterward. Embeddings load on demand, and processing initializes the selected provider's model or service. Readiness does not require provider initialization. See the [startup implementation and validation](../worklogs/2026-10-07-voice-library-startup.md).

Retained limits: the journal has no compaction, so cold rebuild cost grows with event count. Rare durable transitions still perform synchronous journal writes through existing task APIs. Voice preparation jobs remain hydrated by their existing store; their visible history merges into cursor pages, but their persistence does not yet provide bounded payload loading. Voice metadata publication, on-demand embedding reads, and subsequent voice commits still use the main actor. Concurrent writers remain unsupported: revision checks detect conflicts, but a future multiprocess mode needs interprocess locking around append and recovery.
