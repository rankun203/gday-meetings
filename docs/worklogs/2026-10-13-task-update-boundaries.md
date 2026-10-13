---
title: Task updates at committed changes
date: 2026-10-13
status: implementing
scope: macos-task-scheduling
---

## Problem

Frequent saves and broad file fingerprints can cause repeated search maintenance. Editing, task admission, progress, and recovery need distinct boundaries. The reported title-typing churn is not yet reproduced: the previous editor already used a draft, but committed on disappearance.

## Approved scope

This numbered ledger preserves the user's batch decisions. Implementation and validation remain pending unless recorded in the component worklogs.

| # | Trigger | Approved behavior | Owner |
|---|---|---|---|
| 1 | Meeting title | Explicit Save or Return commits; Cancel or Escape discards. No draft indexing. | Editing |
| 2 | Meeting notes | Keep durable autosave; index only when leaving, including closing the app. No idle indexing. | Editing/search |
| 3 | Meeting files | Simple fingerprint of search-relevant content; exclude unrelated writes. | Search |
| 4 | Language | Save immediately; refresh only relevant search changes. | Search |
| 5 | Associations | Refresh metadata per committed action; batch multiple changes; reuse embeddings. | Search |
| 6 | Transcript/revision | Index committed results once; explain existing chunk boundaries and overlap. | Search |
| 7 | Speaker assignment/results | Save complete operation once; cancel superseded work for the same meeting. | Lifecycle/search |
| 8 | Summary checkboxes | Save immediately; checked-state changes do not require embeddings. | Search |
| 9 | Profiles | Short fields commit on Return/focus loss, Escape cancels; longer notes autosave. | Editing |
| 10 | Settings | Only relevant search settings request scans. | Search |
| 11 | Library/model ready | Coalesce checks per library/configuration; queue only stale content. | Search |
| 12 | Rebuild | Explicit operation with progress and cancellation. | Search |
| 13 | Recording stop | Finalize once, honor automation, exclude live checkpoints. | Lifecycle |
| 14 | Transcription | Immediate explicit admission, duplicate protection, index saved result once. | Lifecycle |
| 15 | Automatic downstream work | One task per committed result, including sequential duplicate protection. | Lifecycle |
| 16 | Summary generation | Explicit admission; index complete saved result, never streaming output. | Lifecycle |
| 17 | Manual diarization | Explicit admission and deduplication; complete result boundary. | Lifecycle |
| 18 | Voice preparation | Preserve job identity across pause/resume. | Lifecycle |
| 19 | Imports/external writes | Wait for completion or settled writes; index completed changes once. | Search |
| 20 | Chat | Exclude chat-only changes from semantic indexing. | Search |
| 21 | Repeated requests | Coalesce by meeting/source revision; process newest settled revision. | Search/lifecycle |
| 22 | Progress | Bounded updates to existing rows; routine maintenance stays out of attention. | Lifecycle |
| 23 | Commands | Retry/resume retain intent; attempts separate; dismissal preserves history. | Lifecycle |
| 24 | Recovery | Resume existing intent, not a new request. | Lifecycle |
| 25 | Short operations | Keep archive/context chat/repair transient unless durable controls are needed. | Lifecycle |

## Implemented solution

Implemented in three coordinated components. [Editor boundaries](2026-10-13-edit-commit-boundaries.md) cover items 1, 2, and 9; [task lifecycle](2026-10-13-task-lifecycle-boundaries.md) records admission, cancellation, and already-correct retained contracts. Root integrates the settings UI and [sidebar width correction](2026-10-13-sidebar-window-width.md).

Search fingerprints now encode the existing searchable passages and filter/date/duration metadata deterministically. Chat, language, and checkbox-only state do not change that projection. Association changes update metadata while retaining unchanged passage vectors. A bounded 512-entry actor cache uses file stamps only to avoid rereading unchanged canonical sources, never as the semantic invalidation decision. It checks replacement identity and rejects symlink sources. Every scan pass waits for a two-second quiet interval; active notes editors are excluded from both scanning and admission. Relevant provider/model/readiness changes initiate configuration scans, while unrelated settings changes do not.

Rebuild Search Index now records one durable request with per-meeting child intent identifiers, aggregate progress, and Cancel Rebuild in Data settings. It uses the existing task executor and refreshes index rows transactionally, retaining unchanged vectors and preserving usable search when cancelled. Cancellation is persisted before cancelling children; recovery and late admission check that marker. Deleted meetings are removed from the request's remaining membership. Failed or individually cancelled children produce an incomplete result message.

The first scan after upgrading from timestamp fingerprints refreshes index metadata once. Existing passage vectors remain reusable. This migration should not be described as regenerating embeddings for every meeting.

## Transcript chunking (item 6)

Existing chunking is unchanged. It groups whole chronological transcript segments. Before adding another segment, it starts a new passage if the span would exceed 30 seconds, the gap exceeds five seconds, or text would exceed 1,000 characters. A single longer segment stays whole at this stage. There is no overlap. The encoder recursively halves oversized passages by character count to fit its token limit; this second step can cut words and also has no overlap. Title, notes, and summary begin as separate passages.

## Reasoning

Persistence must protect drafts without forcing semantic work. Supersession concerns obsolete work; unrelated task kinds must retain valid dependencies. Use existing task identity and source-version mechanisms rather than parallel scheduling systems.

## Technical debt

Older task records lack committed source identity, so they cannot be retrospectively deduplicated by source; new records supply that identity. The optional fields preserve compatibility without guessing old provenance. The rebuild manifest is durable request state rather than a second execution scheduler. It groups existing meeting task records in Data settings; Tasks still exposes those child records. This retains the current task schema instead of implementing the broader proposed typed library-task migration in `docs/design/2026-10-06-search-index-tasks.md`. A future migration should move membership/checkpoints to indexed storage and expose the same parent in Tasks; the current manifest rewrites membership at meeting boundaries, which has a scaling cost for very large libraries. The bounded fingerprint cache can reread evicted sources in large libraries; it limits memory instead of retaining an unbounded full-library projection cache. No approximate content comparison or idle-notes indexing workaround was added.

## Validation

The final combined scoped run passed all 110 tests in 17 suites, covering notes autosave/exit/quit integration, content fingerprints, vector reuse, chunk boundaries, source and explicit-request supersession, cancelled rebuild recovery, streaming, voice preparation, and sidebar width/focus. Sidebar validation separates visible keyboard selection from collapsed programmatic navigation: hidden sidebars cannot originate keyboard focus. Formatting lint and diff checks passed. Isolated production builds passed; a final packaging build includes subsequent status-text changes that prevent an active rebuild from displaying stale up-to-date status.

The Command Line Tools linker reports missing search paths for `Developer/usr/lib` and `Developer/Library/Frameworks`. These are existing toolchain search-path warnings, not source deprecations; linking and bundle verification succeed. Generated checkouts, build products, and app bundles remain ignored by the existing `.gitignore` rules.

Baseline Data settings was captured in synthetic Preview. The changed layout keeps the Search Index section, adds aggregate meeting progress, and replaces Rebuild Search Index with Cancel Rebuild while its request is active. Full Preview verified both sidebar reveal routes at 902 points without window growth. After the combined build, CUA reported `cgWindowNotFound` for both Preview and Finder; the Preview process was idle in its normal AppKit event loop. Post-change editor/settings screenshots and real interactions remain pending desktop availability. No real library or provider content was used.
