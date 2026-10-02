---
title: Streamed saved transcript rows and separate recovery
date: 2026-10-03
status: validated
scope: swift-live-transcript-storage
---

## Problem

Stop replayed the complete recognition-event journal even though the accepted transcript was already in memory. Opening live transcript history could also invoke recovery. A compact journal reduced repeated metadata but did not remove these costs. A killed app needed a durable transcript that could be loaded without replaying recognition updates.

## Implemented solution

Stable timed rows append to `live-transcript-segments.jsonl` during recording. Stable observed speaker rows append separately to `live-transcript-speaker-evidence.jsonl`; these are attributed transcript rows, not raw recognition events. An atomic `live-transcript-segments-checkpoint.json` stores committed byte offsets and row counts for both files, recent replaceable rows, manual overrides, speaker metadata, and coverage gaps. Rows are synchronized before the checkpoint is published. Uncommitted trailing bytes are ignored after a crash and truncated before a retry.

One background writer and one replaceable pending snapshot coalesce updates over 250 milliseconds. Persistent immutable blocks identify new rows without copying or scanning the saved history on each update. Older rows append once; only the recent tail and metadata are replaced. Coverage gaps remain in the metadata because finalization no longer rebuilds them from events.

Ordinary live-draft reads use saved JSON or the streamed projection and never replay events. Later saved live edits retain priority. Interrupted-recording recovery prefers the saved projection, falling back to raw-event replay only when the projection is absent or unreadable. Existing adopted or provider transcripts continue using `transcript.json`; RunPod normalization remains unchanged. Library guides describe the new files and supersede earlier replay-first guidance without replacing custom instructions.

Healthy Stop drains provider results and pending writes, commits the final tail and completion metadata, and retires the journal. It does not read, decode, replay, hash, or encode the complete event history, and does not rewrite a full live-draft snapshot. If streamed saving fails, an exceptional full-snapshot save preserves accepted speech. Legacy recovery hashing now reads 64 KiB chunks.

## Reasoning

Stable rows can append safely, but recent recognition and manual edits can change. A committed prefix plus atomic tail prevents duplicate or missing rows if termination occurs between appending rows and publishing metadata. The existing snapshot format remains supported for earlier recordings and explicit saved edits.

## Technical debt

- Stop still materializes accepted rows in memory for the existing adoption API and writes the editable `transcript.json`. Its cost scales with retained transcript content, not superseded event history. Eliminating that final normalized-document write requires changing meeting document authority, editing, search, and archive readers together; it is not claimed here. Measure Stop with an updated endurance run before asserting a memory ceiling.
- Raw-event fallback recovery remains synchronous and retains decoded events. It supports older recordings and damaged or unavailable projections. A future incremental recovery reader should remove that exceptional memory cost.
- A killed process restores the last committed checkpoint. Updates pending during the 250 ms coalescing window or slow/failed storage may be absent; provisional speech is not promoted to final text. Storage failures are reported. Process-crash ordering is covered by tests; sudden power-loss durability across filesystem metadata is not claimed.

## Validation

The final serial suite passed 713 tests in 121 suites in 76.029 seconds. Regression coverage includes saved rows before Stop (including stabilized provisional text), interrupted appends, committed-prefix preservation on retry, edited passages, separate observed speaker rows, invalid event journals ignored by normal reads, unreadable projection fallback, completion metadata without a full snapshot, legacy digest equivalence, and idempotent guide migration. An initial full run exposed one outdated guide-migration expectation; it was updated for the new appended section before the passing final run.

Formatting, lint, and whitespace checks passed. The isolated `make build-macos` release build passed in 153.37 seconds, including property-list and signature validation. Existing linker warnings remain for the missing Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search directories; no API deprecation warnings appeared. No layout or interaction design changes were introduced. Tests simulate interrupted file writes; they do not claim a real multi-hour recording, allocation trace, or system power-loss test. The installed app and ongoing recordings remained untouched. Hosted macOS CI is checked after pushing.
