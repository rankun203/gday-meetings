---
title: Avoid recording-history work when opening saved meetings
date: 2026-10-08
status: complete
scope: swift-meeting-loading
---

# Problem

A supplied Instruments capture records a 3.46-second main-thread hang during meeting loading. Source-label recovery accounts for about 3.34 sampled CPU-seconds within that interval: roughly 1.53 seconds reading a live draft and 1.80 seconds deriving its speakers. These are inclusive sampled costs, not independent end-to-end timings. A concurrent shared library/text-index rebuild accounts for about 17.2 background CPU-seconds across the capture.

The ordinary loader already reads canonical transcript rows. An adopted-meeting compatibility check then rereads the checkpoint and transcript on the main actor. Its eligibility condition also matches ordinary detected voices, whose source-placeholder field is correctly absent. Separately, canonical row reading decodes the entire checkpoint draft just to inspect the recording commit boundary. Oversized historical labeling state magnifies both costs.

# Implemented solution

- `LiveSourcePlaceholderRecovery` checks explicit flags on the loaded transcript rows on a utility task. Meeting loading does not await it. Requests for one meeting coalesce; a no-op check does not publish or save.
- A required correction enters the canonical write queue, revalidates the library generation, transcript, source, speaker attribution, deletion and recording state, and merges into the latest meeting. Unrelated edits and color allocation during a save survive the delayed result.
- `LiveTranscriptProjection.TranscriptCommit` decodes only commit fields. Canonical reads retain interrupted-append boundaries and pending rows without materializing speaker history. The existing on-disk format is unchanged.
- `LiveTranscriptDraft.speakers` builds an ID lookup instead of repeatedly scanning all historical identities.
- Saved-segment access returns the existing rows when there are no aliases. Checking for saved text does not reconstruct speaker metadata.

# Reasoning

Canonical rows explicitly distinguish source placeholders from detected voices. Labels such as a source abbreviation are not evidence of identity. Reading and reconstructing historical labeling metadata adds no information for this repair.

Interrupted recordings still require checkpoint commit metadata: ignoring it could expose an uncommitted append or omit pending rows. Selective decoding preserves that contract. Full draft decoding remains available for explicit recovery and history workflows.

Another task is changing live labeling and post-recording finalization concurrently. Its person and embedding behavior in the speaker getter is preserved. That task confirmed unchanged version-2 commit fields, explicit source-placeholder semantics, and unique speaker IDs; uncertain association uses a separate optional field. Its new recording checkpoint compaction retains referenced identities, aliases, reviews, and voice evidence. It affects subsequent recording saves and leaves existing finalized checkpoints and the evidence journal untouched. Combined integration checks passed for the snapshot containing these changes. No running app or private meeting files were replaced.

# Validation

The isolated loading-only checks passed 49 tests. The combined snapshot passed 77 tests across 16 suites, including one temporary read-only diagnostic. Coverage includes loading, paging, prefetch, interrupted saves, checkpoint compaction, alias retention, source recovery, passage review, association uncertainty, and observation lifecycle. Added fixtures cover a delayed repair, concurrent edits and color allocation, stale results, no-op checks, explicit source flags, scoped passage identities, interrupted commit boundaries, and speaker metadata among retired identities. All committed fixtures are synthetic.

`make build-macos` passed in the isolated combined snapshot, including release packaging, signature verification, and macOS 26.0 minimum/SDK 27.0 checks. `make lint-macos` and diff whitespace checks passed for that snapshot. The Command Line Tools linker reported missing default search paths under `Developer/usr/lib` and `Developer/Library/Frameworks`; no deprecation warnings were reported. These environment warnings were not suppressed. A separate toolchain check with full Xcode should resolve or document those default search paths.

After the snapshot, the other task added overload-recovery changes to `LocalLiveDiarization` and its recovery-window support. Those later changes are outside this build and test result and need that task's final validation. A workspace-wide lint attempt during those edits reported formatting in that service file; the isolated loading/compaction snapshot passed lint. Source contracts were reviewed with the other task through the user. The loading changes are committed separately from the concurrent speaker-labeling work. No push or installed-app replacement was performed by this task.

A temporary read-only release diagnostic compared full and commit-only decoding of the supplied checkpoint in three warm runs of the combined snapshot. Median elapsed decoding time was approximately 759 ms versus 103 ms. The source-label check took less than 0.1 ms and found no correction. These measurements exclude file I/O and UI completion; the private diagnostic inputs and harness are outside the repository.

There are no UI layout or wording changes. The supplied screenshot establishes the affected saved-transcript state. No new app capture or measured click-to-display comparison has been performed.

# Technical debt

- Existing source-label metadata repair remains as a compatibility step for adopted meetings whose speaker metadata lacks source flags. It now uses canonical row evidence without reading history. Removing it requires an explicit metadata normalization/migration and verification of existing records; until then, eligible loads incur a small background row check.
- The checkpoint remains one JSON object. Selective decoding still reads and scans its bytes, though it does not instantiate the unused draft. A future storage change should separate compact commit metadata from retained recording history, with migration and interrupted-write tests. This task introduces no new schema or migration bridge.
- Existing private checkpoints retain their original history. The paired recording-save compaction prevents unused allocations from being copied into new checkpoints, but does not rewrite old files or reconstruct missed recognition. Full transcript-history requests can still decode an old draft in the background.
- Library/text-index reconciliation can rebuild unchanged passages after ancestor-directory events and reindex one meeting for several paths. The separate lifecycle review identified these costs; fingerprint-based scan reconciliation and deduplication by meeting remain follow-up work. Semantic query preparation is lazy, but catalog/text monitoring and configured semantic-index freshness checks can run before a query.

# Notes

The captured index rebuild cannot be attributed to a specific event flag or path from sampled stacks alone. A healthy startup does not unconditionally rebuild the text index. Missing or invalid index/cursor state, dropped or ancestor events, recovery after failures, and an explicit rebuild request can trigger it.
