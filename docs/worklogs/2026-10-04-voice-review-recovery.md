---
title: Voice review recovery and task visibility
date: 2026-10-04
status: implemented
scope: swift-people-tasks
---

# Voice review recovery and task visibility

## Problem

Migrated voice embeddings appeared as fresh suggestions without playable ranges or model details. Opening a recording did not locate the original speaker. Speaker labeling appeared only in background activity below completed Tasks, and voice preparation lacked persistent task presentation.

## Design

The supplied People, Review Voices, and Tasks screenshots establish the current interaction state. Retain the native review sheet and controls. Show the person, sample, and model representations, with confirmation distinct from a suggestion. Voice Details includes source, model revision, recorded provenance, and compatibility. Resolve safe source ranges from saved transcript metadata and offer an explicit recovery action when metadata is insufficient. The latest screenshot feedback requires confirmation without playable audio and one model list without age-based categories. Audio availability governs playback and extraction; model validity and compatibility govern matching.

Open Recording selects Transcript and locates the saved speaker's first passage when the example lacks an exact range. Opening a recording does not start playback; timestamps remain explicit playback actions. An unavailable or ambiguous target must not navigate to a guessed person.

Tasks presents active work before completed history. Speaker Labeling records its lifecycle through the managed task journal. Voice preparation and discovery retain their existing authoritative job records and expose persistent progress, recovery, and completion in Tasks without maintaining a second conflicting state store.

The follow-up Transcript screenshot shows Label Speakers without evidence of past work. Add a concise last-known-run tooltip and a neighboring, keyboard-accessible Speaker Labeling History popover. Include durable tasks and saved labeling result files from older versions; distinguish unavailable history from evidence that labeling never ran. Show model/provider metadata only when retained. History inspection must not start labeling or replace the transcript. After inspecting the first preview screenshot, the user requested shorter entries: use a date/status row, provider/known-model row, and only useful progress or failure details. Omit repeated completion and missing-model messages; explain uncertain historical application once below the list.

The additional People screenshot shows an unsorted directory and a creation-only field. Keep the existing list and add control. Sort names using locale-aware natural ordering with a stable ID tie-breaker. Rename the field to **Find or Add Person**, filter names as the user types, and provide a clear action. Return selects an existing exact name without case or diacritic distinctions, otherwise creates the person; the Add button explicitly creates a person. Keep excluded-person filtering.

## Implemented solution

- Samples retain person assignments and model provenance. Selected examples recover an unambiguous source excerpt from saved speaker metadata without model inference. Confirm and Assign remain available without a playable excerpt. Compatible valid vectors contribute to confirmed identities regardless of import origin; rejected evidence prevents repeat suggestions.
- Voice Details shows one list of model representations, revisions, compatibility, dimensions, recorded provenance, and review status. Unknown metadata remains unknown. Missing or replaced audio affects playback and fresh extraction rather than the identity represented by a saved vector.
- Known Rust/RunPod vectors use the verified Community-1 embedding contract; explicit provider metadata takes precedence. The worker pins its upstream model and publishes normalized, typed output. Its image must be rebuilt to emit the new metadata; no remote deployment was performed. Existing raw output remains usable through the known contract.
- Open Recording scrolls to and selects the related passage without changing playback. A speaker-origin mapping survives review-generated speaker IDs.
- Speaker Labeling uses persistent managed tasks with progress, cancellation, explicit recovery, and source-revision checks before saving results. Tasks puts active work first and includes existing voice preparation/discovery jobs.
- Label Speakers has a latest-record tooltip and an accessible history popover. History reads bounded metadata from older receipt files and merges new task/result records by exact UUID only.
- Three sub-agents handled task/history persistence, source recovery, and UI/navigation. Integration review checked audio replacement handling, confirmation, durable rejection, and task counting.
- Speaker chips use distinct meeting-local palette slots instead of independent hash buckets. Slots persist with changed meeting metadata and survive person assignment and renaming. Split corrections receive distinct slots while repeated passages for the same corrected identity share one. Read-only recordings derive slots without writing. Live model slots pass through attributed phrases into saved speakers, preserving color when recording stops and the meeting reopens. Source placeholders share their source color without merging passage assignment IDs. Eight semantic colors are followed by generated hues; text labels and the unresolved outline remain necessary distinctions when many colors become perceptually similar.

## Reasoning

Existing recordings can provide reviewable evidence without running a new model just to open People. Source recovery and embedding preparation are separate operations. Task visibility must reflect saved work and recovery state, not just a transient activity count.

## Technical debt

Incremental voice storage separates authoritative example metadata, model representations, jobs, decisions, Undo entries, and deleted-person records. A bounded redo transaction records changed files, with revision and touched-file checks to reject stale writers. Writable recovery replays a committed update; read-only recovery overlays it without changing files. Plain files remain authoritative. Conversion is explicit, outside normal app startup; the temporary migration command defaults to a dry run, requires the app to be stopped for apply, preserves a byte-verified original, verifies the staged records, and retires the active predecessor only after publication. Remove the temporary converter after development libraries have switched. No runtime monolithic reader or dual writes remain.

The integration retains all lightweight example metadata in memory and linear metadata scans in several store queries. Lazy vector reads address payload amplification, but do not establish bounded metadata memory or paged review. Remediation: measure representative libraries, add metadata indexes for repeated person/recording/group queries, and introduce paged metadata loading when needed. SQLite, if used for that index, must remain disposable. Explicit grouping and profile calculation can still read many candidate vectors; bound or cache those workloads based on measured costs.

Repository-wide JSON storage audit remains open. Triage every JSON file by its purpose, expected growth, read scope, mutation frequency, atomicity requirements, and recovery needs. Keep ordinary JSON for small, infrequently changed documents; split independently accessed or updated entities into separate records; use an append-friendly format where the data represents events or incremental changes. Evaluate indexing and compaction where needed, and avoid a blanket format conversion. Until this audit is complete, other large or frequently updated documents may retain unnecessary read/write amplification. Remediation: inventory producers and consumers, measure representative workloads, select a format per file type, and implement verified migrations and regression checks for each justified change.

Completed voice jobs remain visible because their records also contain discovery receipts; a future retention feature must separate display dismissal from evidence deletion. Historical labeling files cannot establish whether every old analysis was applied; the UI preserves that uncertainty instead of introducing heuristic links. No duplicate task journal was added for voice preparation. The prior voice-library storage and calibration limitations remain documented in the October 3 worklog.

## Notes

Validation uses synthetic libraries and an isolated release build. The concurrent UI-theme documentation changes are outside this task.

- Integrated serial suite: 808 tests in 138 suites passed. After live-to-saved color continuity changes, 80 tests in six affected suites passed. Final vector ingestion and replacement-audio safeguards passed 70 tests in six affected suites.
- Five Python migration tests passed. A Swift regression runs the converter on synthetic input and loads its output through the production decoder. Worker validation: 21 tests passed, one optional CPU model smoke test skipped; no model download or inference was performed.
- Formatting, Swift lint, and whitespace checks passed.
- Regression coverage includes incremental writes, lazy vectors, transaction recovery, stale writers, confirmation without audio, compatible model reuse, incompatible and malformed provider metadata, rejection and Undo, source replacement, task recovery, history deduplication, persistent colors, and transcript navigation without playback.
- Final isolated release build passed after all code changes (72.89 seconds). macOS CI matrix verification follows the push.
- Preview captures verified recovery to a playable timed excerpt, one model list, enabled confirmation without audio in light and dark appearances, active labeling in Tasks, paused/failed voice jobs, and compact history. Silent playback reached the recovered end time. Final navigation shows the target passage outlined with distinct speaker colors and playback unchanged.
- Native navigation retains a target until rows arrive and draws its selection explicitly because the table suppresses ordinary selection styling. Preview caught and corrected case-sensitive exact-name submission and duplicate recovery messages; the refreshed build selects the existing mixed-case name and shows one recovery message beside the sample. History popovers extend outside the captured sheet bounds, so accessibility inspection also verified all rows.
- No real user audio was analyzed, no provider upload was started, and recognition accuracy was not evaluated in this follow-up.
- The local Command Line Tools installation reports missing linker search directories for `Developer/usr/lib` and `Developer/Library/Frameworks`. These are toolchain path warnings, not deprecation warnings; no deprecated API warning was observed. CI validates the supported Xcode matrix.
