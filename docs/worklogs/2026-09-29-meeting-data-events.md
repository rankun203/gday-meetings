---
title: Meeting data event history
date: 2026-09-29
status: complete
scope: swift-data-flow
---

# Meeting data event history

## Problem

Settings described possible data destinations, but a meeting had no record of actual file changes or successful transfers. Provider return types had no shared data-flow receipt.

## Implemented solution

- Added a fifth **Data Privacy** meeting tab. Rows show successful creation, modification, sending, and receipt of data, with specific filenames or source types, purpose, local or remote destination, and time. Expanding a row shows domain, start, end, duration, and measured request and response body bytes. Files and the meeting folder can be revealed in Finder. Missing sizes are described as not measured.
- Added `ProviderDataResult` and `ProviderResult<Value>`, with a required `DataFlow`. Content adapters return this envelope for uploads, transcription submission and results, summaries, chat, website archives, and This Mac live recognition. Capability protocol extension points use the same envelope. Discovery calls also return receipts; they are not attributed to unrelated meetings.
- Saved metadata-only events in each meeting's append-only `data-events.jsonl`. No audio, text content, request headers, credentials, or signed download URLs enter the journal. Dates retain millisecond precision; duration is derived from the timestamps and serialized explicitly.
- Kept uploads separate from later processing. A successful upload remains visible if submission or processing later fails. Complete summary responses are recorded before stale-content checks, so a result that cannot replace edited local content still has its successful transfer recorded. Context chat records its receipt in every included meeting.
- Logged document changes after transaction commit, comparing bytes to suppress no-op rewrites. Notes, note images, transcript checkpoints and revisions, archive checkpoints, and audio persistence use their successful write boundaries. Audio and image event metadata uses file size without reading the payload. Finalized source tracks record their modification before encoding.
- Recorded live recognition start and end as append-only revisions with one event ID. The history presents the latest revision. Bytes remain unknown for the live session. Task state and polling attempts remain in Tasks.
- Tolerated incomplete or malformed JSONL lines while retaining later valid events. The tab reports the unreadable-line count. History is loaded off the main actor and reread only when the journal changes while the tab is visible. Synthetic preview history includes local and remote receipts without network requests.
- Made audit failure after a successful file write a separate warning. It does not roll back saved content or cause an upload retry.
- Covered preview manifest and thumbnail writes, retained archive audio conversion files, and successfully published JSON, Markdown, and TextBundle exports. Export receipts stay in the originating meeting folder and name the output files without recording absolute paths. Failed export staging and rolled-back sidecars do not create export receipts; output sizes use file metadata rather than rereading payloads.

## Reasoning

The mandatory result envelope makes the provider boundary responsible for describing a successful data operation. Scoped transport measurements supply body byte counts without retaining the body. Persistence remains independently responsible for file creation and modification. The history therefore answers where data went, while Tasks continues to answer whether work is pending, running, or failed.

The existing capsule navigation remains intact with a fifth tab. Details stay collapsed to keep filenames, destinations, and purpose easy to scan. Received transcript results use a separate received action so the interface does not imply that a transcript was uploaded when it was downloaded.

## Validation

- The integrated Swift suite passed all 455 tests in 88 suites. An earlier full run had one summary-stream timing timeout; all nine streaming tests passed in isolation, and both subsequent full runs passed.
- Isolated UI Preview showed the fifth tab during recording and after saving, live refresh of persisted file events, local and remote receipts, expandable timing and byte details, and file reveal controls. Screenshots in light and dark appearances matched the design. No user meeting content was used in fixtures.
- `make format-macos`, `make lint-macos`, and `git diff --check` passed. The packaged preview build passed with existing standalone Command Line Tools linker warnings for missing toolchain search directories; there were no source deprecation warnings.
- Added journal and receipt tests for byte measurements, failure behavior, scoped measurements, damaged final lines, timestamp precision, no-op changes, privacy of stored metadata, and failed saves.
- Existing transport tests verify mandatory receipts; summary streaming checks cover complete responses and excluded failed streams.
- Real network providers and microphone hardware are not exercised by opening the synthetic preview.

## Technical debt

- The journal is appended synchronously under a process lock. Small metadata records avoid whole-history rewrites and per-event forced disk synchronization, but sustained high-volume logging may need a serial writer with explicit shutdown flushing. Audio buffers never append journal records. The tab currently loads the complete history after a change; a paged reader should replace this if large histories make refresh expensive.
- The log records app-observed successful writes and provider calls from this version onward. It does not reconstruct earlier activity or monitor arbitrary external file edits. A future filesystem audit would need explicit provenance and conflict handling rather than inferred historical events.
- If journal persistence fails, saved data and completed provider work remain successful and the app reports the missing audit record. There is no durable retry queue for failed audit appends. Adding one would need idempotent event identifiers and bounded storage independent of the meeting folder.

## Notes

Source mute behavior and recording-list anchoring are separate changes with their own worklogs. These events describe data movement, not provider retention policies or proof of remote deletion.

Final review corrected summary and transcription receipts to reference `content.json` for language and expanded archive receipts to list snapshot artifacts and audio filenames without signed URLs. Both cases have regression coverage; the final suite passed all 467 tests in 89 suites.

## Empty-state layout

An isolated preview with its synthetic journals temporarily moved aside reproduced the left-shifted empty state. The unavailable-content view retained its intrinsic width inside a leading-aligned stack. It now fills and centers in the space below the header. The title and Reveal Meeting Folder action retain one full-width horizontal row; the action keeps its intrinsic size to avoid wrapping. The outer pane fills available width and height. No added technical debt. Validation: the rebuilt isolated preview confirms the empty-state center aligns with the content-pane center, and the title and folder action remain on one row. Build, formatting, lint, and whitespace checks passed. Existing Command Line Tools linker-path warnings remain. Synthetic journals were restored after verification. No new tests were added for this layout-only change; persistence and event processing are unchanged.
