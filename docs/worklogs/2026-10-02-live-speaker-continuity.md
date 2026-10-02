---
title: Live speaker continuity and bounded transcript updates
date: 2026-10-02
status: validated
scope: swift-live-transcript
---

# Problem

Live speaker labeling alternated detected speakers with unassigned labels during continuous speech. Attribution, array comparisons, checkpoint copies, and native display updates still did work proportional to the accumulated transcript. Long recordings could therefore interrupt typing and scrolling.

# Implemented solution

- `LiveTranscriptStream` carries the previous detected speaker forward independently for each audio source. Unknown leading speech has no speaker badge. A source change, recognition session change, model generation change, or audio gap prevents carrying an earlier identity into unrelated audio. Raw word attribution remains independent of this fallback.
- Final recognition and emitted speaker coverage seal a chronological prefix across selected sources. Only the remaining recent tail is attributed again. A 30-second deadline bounds stalled labeling and silent-source ordering waits. Timed volatile recognition older than that deadline is stabilized too; subsequent provider corrections cannot rewrite it. Raw evidence retains `recognitionFinal: false` for this case. Untimed recognition remains intact because inventing word boundaries would lose or misplace text.
- Immutable blocks retain raw and effective frozen rows. Explicit revision numbers replace historical array comparisons. The native table consumes an indexed frozen prefix, regenerates only its tail, and retains preceding row identities and height caches. Paragraphs retain the existing 30-second limit and stop joining at 2,000 UTF-16 code units.
- During recording, ordered private JSONL events replace repeated full checkpoint encoding and historical array copies on the UI actor. The background writer bounds pending records, validates its header and committed records, tolerates an interrupted trailing record, and reports failed writes. A failed journal remains visibly failed because it cannot claim to have saved skipped mutations.
- Stop materializes a full snapshot away from the UI actor, saves effective assignments in `live-transcript.json`, and saves per-word observed assignments in `live-transcript-word-speakers.json`. The raw file distinguishes missing labels, word timing, and nonfinal recognition. The recovery journal moves to `live-transcript-events.saved.jsonl` only after the snapshot succeeds. A committed digest makes the snapshot authoritative if journal retirement is interrupted; later saved edits remain authoritative. An interrupted recording replays the active journal. The immutable in-memory transcript remains available for a final snapshot if journal storage failed.
- Text edits and person assignments explicitly invalidate the affected presentation. Captured override ranges have one owner across frozen, finalized, and partial rows, so crossing the cutoff does not duplicate edited text. Person-only edits retain paragraph boundaries.

# Reasoning

Nemotron emits new activity ranges; its cache does not revise minutes of prior output. A prior speaker fallback is therefore a presentation and saved-transcript decision, not new model evidence. Waiting indefinitely for perfect attribution would leave history mutable and allow processing costs to grow.

The reference-owned stream and append journal remove repeated historical work from ordinary live events. Stop materializes the saved transcript off the UI actor. Reopening an interrupted recording replays the journal once through the existing synchronous loader; that recovery can block its caller and needs separate measurement. Explicit user corrections may invalidate historical presentation because the person requested a historical change.

# Technical debt

- The 30-second stabilization deadline is a deliberate accuracy tradeoff. Late label evidence and revised ASR words before the cutoff do not rewrite frozen words. Recorded Speaker Labeling or a manual correction can change the saved result later. Tune this deadline only with latency and quality measurements; indefinite provisional history would reintroduce the original cost.
- A provider can emit a single untimed phrase whose text grows without limit. It cannot be split safely, so processing that input still scales with its size. The Apple provider normally supplies timed words; tests retain all text for untimed input. A future provider must supply reliable timing or documented bounded segments to obtain the same tail bound.
- A source can deliver previously unseen recognition after the 30-second ordering deadline. It appends as a separate late row with its original timestamp, preserving frozen history and all new text. Saved transcript generation sorts rows once. Supporting arbitrary late chronological insertion without regenerating the native prefix would require an indexed insertion model and a separate viewport design.
- Interrupted-recording recovery uses the existing synchronous document loader. Large journals can delay opening a meeting even though live updates and stop materialization avoid historical work on the UI actor. Measure recovery latency, then move document recovery behind asynchronous loading if material.
- Raw and effective JSON files are individually atomic, not a multi-file transaction. The full snapshot also retains its raw attributed phrases, allowing the separate word artifact to be regenerated. The active journal remains recoverable until both writes succeed; any failure is reported.

# Validation

Focused core tests cover source-scoped fallback, raw uncertainty, delayed diarization, delayed recognition, session and gap barriers, two hours of stalled labels with bounded attribution counts, growing timed partials, intact untimed text, override ownership, invalid input, and journal retirement followed by saved edits. Existing detached-session finalization and storage-error tests also run. Journal tests cover ordered replay, private permissions, bounded failure, malformed records, and interrupted writes.

A focused integrated run passed 59 tests in six suites in 1.147 seconds. Additional recovery-commit and timestamp-boundary regressions were added afterward. The final serial suite passed all 694 tests in 118 suites in 64.216 seconds. The default concurrent run hit five-second deadlines in summary, managed-task, and live-storage fixtures under main-actor contention; those fixtures passed serially without changing production timeouts. Lint and diff checks passed. An isolated `make build-macos` release build passed in 63.91 seconds, including signing and property-list validation. The Command Line Tools linker still reports two missing toolchain search directories; no new API deprecation was reported.

Before/after isolated previews verified compact rows, blank leading attribution, carried labels, speaker changes, editing while speech continues, paused scrolling, Follow Live, and saved/reopened assignments. The final release synthetic replay was also inspected and stopped successfully. Its deliberately incomplete provider fixture reports possible missing audio after stop; this does not validate real capture completion. CI and installation results are recorded below. No sustained real-audio quality or Instruments result is claimed here. The follow-up [performance evaluation plan](2026-10-02-performance-evaluation-plan.md) includes representative recordings, resource usage, and UI response measurements.

# Release handoff

Feature commit `170a050` is pushed to `master`. [macOS CI run 36983011439](https://github.com/rankun203/meeting-notes/actions/runs/36983011439) has started all three release jobs: macOS 15 with Xcode 26.0.1, macOS 26, and macOS 27 preview. All three jobs passed; no runner was unavailable.

The validated release is installed at `/Applications/Gday Meetings.app`. Installation verified the signature and exact executable hash against the isolated release build. The previous application bundle is retained at `/private/tmp/Gday Meetings.before-live-continuity.app`. The user will open the installed app, clear permissions, and start recording before real-audio profiling. Free disk space at handoff was 172 GiB. No sustained recording or active summary performance claim is made yet.
