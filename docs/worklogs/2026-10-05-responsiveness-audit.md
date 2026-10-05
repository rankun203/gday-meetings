---
title: macOS responsiveness audit
date: 2026-10-05
status: complete
scope: macos-concurrency-and-persistence
---

# macOS responsiveness audit

## Follow-up status

This report records the original audit and its first bounded receipt optimization. The later authorized [asynchronous persistence refactor](2026-10-05-async-persistence.md) replaces the canonical save, task journal, notes, external reload, and cold-load paths identified below. Its integrated validation is tracked separately. The findings and line numbers below describe the audited snapshot, not the final refactored implementation. Summary rendering and other remaining synchronous boundaries still require separate profiling.

## Problem

Summary generation in an earlier build coincided with slow interaction and playback controls that did not respond. The report alone does not identify the blocked stack. Static review can identify remaining blocking paths but cannot prove which caused that incident.

## Review method

The requested Claude Code session used `claude-opus-5-5`, confirmed by the completed CLI result's canonical model field. Claude Code 2.1.289 received a temporary copy of application source and tests only. Hooks, MCP connections, browser integration, shell execution, writes, and session persistence were disabled. The audit did not inspect or upload the meeting library. The session completed successfully in 76 turns with no denied tool calls. Findings below were checked against the working source independently.

The snapshot did not include `Package.swift`. Review of the actual manifest resolved the audit's isolation uncertainty: the target declares Swift 5 language mode and does not enable default main-actor isolation or `NonisolatedNonsendingByDefault`. The audit did not establish that the network stream's byte parser runs on the main actor. Its broader claim that only explicitly detached tasks, queues, and actors leave the main actor was not adopted. References below describe the working files after the receipt optimization, rather than the older snapshot's line numbers.

## Implemented solution

`MeetingStore.save()` now limits document-event snapshots and comparisons to the files it writes. Summary-only saves no longer read the complete transcript twice merely to discover it has not changed. A transcript owned by the live recording writer is also excluded from an unrelated save's receipts. Transcript saves still record their actual changed byte counts. A shared transcript-ownership predicate controls receipts, transaction rollback files, and actual writes. Conflict checks, canonical writes, transaction completion, and provider checkpoint durability retain their previous ordering.

The reduction is two transcript-file reads and one transcript-sized baseline allocation per summary-only save. This is a structural reduction, not a measured UI latency claim. The required canonical conflict read remains.

## Consistency boundaries

| State or operation | Required boundary | Appropriate execution |
| --- | --- | --- |
| Play, pause, selection, visible task progress | Immediate in-memory state | Main actor; avoid file or database access before accepting the action. |
| Provider submission intent and remote task binding | Durable before sending or resuming a request | Serialized background journal commit, awaited before the external operation. Never replace with fire-and-forget persistence. |
| Final summary, transcript, edited notes | Durable before reporting save success | Serialized persistence with conflict checks and ordered revisions. Keep the UI responsive while awaiting completion. |
| Search index, waveform cache, list projections | Eventual, derived from committed source | Background work with revision checks; discard stale results and rebuild failures. |
| Task progress text | Immediate visible state; eventual durable copy | In-memory update; the next durable task transition captures it. |
| Data-event receipts | Ordered after the canonical operation they describe | Preserve operation identity and timestamp; report receipt failures separately from canonical save failures. |

Here, a durable boundary preserves the existing operation's persistence guarantee. Task journal appends synchronize their file handles; ordinary document and notes writes use atomic replacement. This audit does not claim that every existing save is protected against sudden power loss.

## Confirmed findings

1. **High: canonical saves still block the main actor.** `MeetingIntelligence.swift` completes summaries through `updateMeeting`, which calls the synchronous `MeetingStore.save()` pipeline. That pipeline reads conflict baselines, flushes notes, writes canonical files, records receipts, and updates SQLite. The bounded read reduction above does not remove this risk. Move the transaction behind a serialized persistence owner only after specifying revisions, in-flight edits, recording ownership, external conflicts, error publication, library switching, and termination flushes.
2. **High: durable task transitions can block the main actor.** `ManagedTasks.saveManagedTask` reads and upserts the journal synchronously; `ManagedTaskJournal` locks, updates the index, and synchronizes file handles. `IndexDatabase` configures a five-second SQLite busy timeout. A background rebuild can also contend for journal locks. Keep journal-before-provider ordering while awaiting a serialized worker. Progress-only updates already avoid journal writes.
3. **High: notes debounce delays work but does not move it off the main actor.** `NotesStorage.schedule` creates a task in an explicitly main-actor class; after its delay, `flush` calls file reads, conflict-copy writes, image preview preparation, and cleanup synchronously. Separate derived previews from durable text, and introduce per-meeting revisions and explicit flush barriers before changing text persistence.
4. **Playback transport is already queued.** `StreamingPlayback.pause` enqueues the engine operation on its playback queue. Audio decoding and playback preparation use that queue. An unresponsive main actor can prevent the user's pause action from reaching it; the presence of a playback symptom does not establish a decoder fault.
5. **High: external meeting reloads reread every loaded clean meeting.** The reload request retains only broad change categories. `reloadExternalLibraryDocuments` then decodes full meeting documents on the main actor, without restricting reads to the affected meeting paths. Local file writes can also trigger this work through the folder monitor. Preserve affected IDs, read snapshots off the main actor, and publish only when local revision and library generation still match. External edits must remain observable; simple time-based suppression is insufficient.
6. **High: task-state rendering can query the journal.** When queued tasks exist, `isJobRunning` queries journal storage and is called by SwiftUI views. Use one authoritative in-memory active-task projection with immediate enqueue reservations, reconciling restore, external updates, removals, and durable transitions. Adding an independent cache without these reconciliation rules would create stale-state debt. Double-click prevention must not depend on a delayed projection catching up.
7. **Medium: opening an uncached meeting performs synchronous reads and can write.** `ensureMeetingLoaded` reads and decodes the meeting. `meeting(id:)` may also save applied voice decisions. Use an explicit async load, selection and library generation checks, and separate recovery commands. Do not resurrect a meeting deleted while its load was pending.
8. **Medium: summary rendering still rebuilds complete Markdown.** Each changed partial invokes the native renderer, including attributed-string parsing and citation regex construction. Throttling limits frequency but not per-render cost. Profile a large synthetic summary; then consider shared regexes and latest-result scheduling before attempting incremental parsing, whose output must match a full render.

### Source locations

All paths are under `apps/client-macos-swift/Sources/GdayMeetings/`.

| Finding | Verified entry points |
| --- | --- |
| Canonical save | `Core/MeetingIntelligence.swift:135`; `Core/MeetingStore.swift:341`, `:737`; bounded receipt reads at `Core/DataEvents.swift:286` and `:293` |
| Task durability and lock contention | `Core/ManagedTasks.swift:167`; `Core/ManagedTaskJournal.swift:193`, `:233`; `Core/IndexDatabase.swift:115` |
| Notes flush | `Core/NotesStorage.swift:26`, `:44` |
| Playback control | `Core/StreamingPlayback.swift:191` |
| External reload | `Core/MeetingStore.swift:536`, `:589` |
| View-triggered journal query | `Core/BackgroundJobs.swift:63` |
| Cold meeting load and getter writes | `Core/MeetingPaging.swift:107`, `:122` |
| Summary rendering | `Services/LLMStreaming.swift:154`; `UI/NativeMarkdownReadingView.swift:36`, `:579` |
| Recording completion compounds saves | `Core/MeetingStore.swift:1089` |

## Prioritized follow-up and acceptance tests

1. Add operation signposts for save, journal commit, external reload, notes flush, and summary rendering. Measure main-run-loop latency during a large synthetic summary and delayed-storage operations. A queued playback pause must be accepted while background work is held behind a test gate.
2. Scope external reloads to affected meetings and move their reads off the main actor. Test that editing meeting A does not read B; a real external change is reflected; a local edit or library switch during the read rejects stale output; deletion is not undone.
3. Remove storage reads from task-state presentation. Test zero journal reads during repeated view updates, one task after a double-click, no provider request before intent commit, and cancellation during a pending enqueue.
4. Move journal transitions to a serialized worker while awaiting required commits. Inject a slow append, failure, and concurrent history read; verify responsiveness and preserved journal-before-provider ordering.
5. Introduce ordered notes persistence and explicit flush barriers. Test the final character survives immediate quit, a later edit wins over an earlier slow write, external conflicts retain both copies, and flush failures prevent success reporting. Preview images are a separate derived operation.
6. Introduce the revisioned canonical writer. Test newer edits survive an older save's failure, disk conflicts do not overwrite external data, task completion waits for the summary commit, and started transactions complete despite caller cancellation. Library switching and application termination must await committed work. Move derived index refreshes after that boundary.
7. Optimize the summary renderer only with output-equivalence and final-partial tests. Measure a 50 KB synthetic summary before and after; do not treat a timing threshold on an overloaded CI machine as the sole correctness test.

The current summary draft isolation, 100 ms streaming throttle, background image preparation, and presentation-only task progress updates are confirmed mitigations. No hang trace or comparison against the exact earlier installed binary was captured, so the incident remains unattributed.

## Validation

- Added a synthetic regression for a summary receipt while an independent transcript writer advances the file: the summary save records only its own output.
- Added a store-level regression proving changed transcripts retain accurate receipts while summary-only saves do not claim a transcript change.
- All 11 `DataEventTests` passed initially. The final shared transcript-ownership predicate then passed the integrated 74-test, 13-suite run in 6.336 seconds, including summaries, recovery, receipts, toolbar state, and waveform scrolling.
- Formatting, lint, and `git diff --check` passed. Release validation uses the working checkout: only the installed Applications copy was running, and the separate Preview was quit before packaging.
- The first compiler invocation hit the environment's nested sandbox restriction; the authorized retry succeeded. The sub-agent's Command Line Tools run reported missing `Developer/Library/Frameworks` and `Developer/usr/lib` linker search paths. The integrated run selected `/Applications/Xcode.app/Contents/Developer` and produced no warnings, resolving those toolchain-layout warnings without changing source or suppressing diagnostics. No deprecation warnings were encountered. The integrated release passed in 154.45 seconds without warnings and passed platform/signature validation. At this validation checkpoint, the changes had not been pushed and CI had not run.

Final combined validation: formatting and lint passed; the Xcode release build including the footer and transcript sizing changes completed in 150.76 seconds without warnings and passed platform/signature checks. The synthetic Preview is labeled `40e64af-sidebar-review`. The installed app was preserved. Targeted footer and transcript tests passed separately after those additions; the earlier integrated 74-test run covers the remaining changes. At this validation checkpoint, no commit or push had been made and remote CI was unavailable for the working tree.

## Technical debt

Existing synchronous canonical saves, task journal transitions, and notes persistence remain. They were retained because moving these calls into detached tasks without a serialized ownership and revision protocol risks reordered saves, stale overwrites, lost termination writes, and duplicate provider submissions. Follow-up: introduce explicit asynchronous persistence commands and awaitable durability barriers, then move derived index and preview updates behind committed revisions. No new persistence bridge or schema debt was introduced by the bounded receipt change.
