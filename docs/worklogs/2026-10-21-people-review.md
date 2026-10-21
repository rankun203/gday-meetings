---
title: People library review
date: 2026-10-21
status: validated-for-commit
scope: swift-people-review
---

# People library review

## Problem

People review was difficult to discover and complete. Global review could disappear with a dismissed notification, while person-level actions opened empty queues. The separate Identify People interface used a different model, clipped its left column, repeated equivalent audio, and provided little context for prioritizing unnamed people. Existing voice evidence was unavailable during candidate review. Playback, naming, selection, progress, and saving did not behave consistently. Selecting a person could also replace the native detail pane and move the divider.

## User Intention

Keep People as a name-first directory with associated meetings and details. Make library review a prominent, uncrowded bar above both panels, independent of the selected person. Use **Review Library** globally and **Review This Person** for the selected person, without ellipses. Show actionable counts, say “people with new matches,” and use “unnamed people” rather than internal grouping terminology.

Use one listening flow for named people and unnamed proposed people. List named people with pending matches first, then unnamed people. Keep one compact chooser row per person, with sample counts, the meeting containing the most recent pending sample, and additional-meeting context. Audio cannot be recognized visually; meeting titles help users prioritize important or familiar work. Retain recording-title search and clearly distinguish meetings with repeated titles.

Opening a new dialog selects the first displayed sample. Selection owns playback: stop the previous excerpt immediately and play the selected one. Keep existing reference samples playable without losing the current candidate. Confirm, reject, ignore, skip, correct, and undo individual samples while retaining completed rows and visible progress. Reveal the active row after advancing. Naming an auditioned sample should create or choose the person and associate the proposed group in one action; other samples remain individually reviewable and correctable. Double-click naming must work for both named and unnamed labels.

Keep the identity question and playback above transcript context. Show text from the exact audio source and range, highlight only actual word timings, and show “Transcript unavailable” when appropriate. Keep three-line sample rows: meeting title; meeting date/start time before excerpt range and duration; status symbol and text. Use quiet tinted labels that look distinct from action buttons. Keep repeated-confirm click targets stable and show saving inside the initiating button.

Fix architecture and lifecycle rather than masking symptoms with fixed widths or duplicated state. Preserve earlier intentional features, person-scoped drafts/loaders, saved divider preferences, native sidebar transitions, and normal resizing. Use source review, meaningful regression tests, synthetic states, and periodic Claude Code Opus 5.5 review. Protect the main library, preserve trial decisions, and provide reset copies for repeated testing. The user completed Astra 6.1 testing and authorized committing and pushing the changes.

## Design and evidence

Inspected the supplied screenshots and captured the existing isolated synthetic Preview before UI changes. Baseline evidence showed the name-first directory, empty review entries, card-based identification, edge-clipped content, missing references, and playback handoff failures. Later captures compared compact chooser rows, light/dark appearances, the bar above both panels, review controls, transcript placement, labels, and native divider behavior. Synthetic playback is silent and establishes control behavior rather than audible recognition quality.

The final design retains the directory and associated-meetings layout. A permanent library bar presents a people symbol, headline, one summary line, and Review Library. It remains available during loading, failures, and empty queues. The chooser and person controls expose only actionable work. Named and unnamed people open the same sample-list/detail dialog; the former Identify People interface is retired.

## Implemented solution

### Shared review state and lifecycle

`VoiceReviewSnapshot` is the store-owned source for named queues and unnamed proposed groups. The chooser, bar, person controls, and review dialogs consume the same eligibility and counts. Cached hydration is shared across readers. Decisions, person deletion, and in-app recording deletion or audio replacement invalidate immediately. Explicit Refresh rechecks external audio changes.

Preparation progress does not invalidate review evidence. Model-only updates coalesce after 300 ms of quiet, with two-second batches deferred until active reads finish. Completed UI results remain visible while these tentative scores refresh. Review reads validate decision metadata while permitting independently updated model representations; matching/profile reads retain stricter representation validation. Canonical saves are awaited cancellably, and stale requests cannot publish results.

The permanent bar owns its task independently of conditional empty content or notification dismissal. Opening the chooser transfers read ownership; closing rereads the shared snapshot even when the evidence revision is unchanged. Person availability shares this presentation lifecycle so successful retry recovers both entry points. The obsolete dismissible `VoiceReviewNotice` helper is removed. Header and conventional menu entry consume one loaded person availability value; the duplicate Edit Profile summary is removed. Ignored samples are excluded from associated totals.

### Listening, naming, and durable decisions

`PersonMatchReviewView` and `VoiceMatchReviewSession` retain row order, progress, navigation, naming snapshots, corrections, and exact-action Undo receipts. New sessions select the first displayed sample; refresh preserves deliberate navigation and can select newly arrived work after completion. Selection changes reveal the active row. One compact playback control owns the selected excerpt, pauses for naming, and stops on dismissal or recording navigation. Failed saves retain the undecided sample and offer recovery.

Existing samples use the same effective-state actions as candidates: associated samples can be confirmed, confirmed samples corrected, and skipped samples revisited. Disabled action slots remain in place after confirmation so repeated clicks cannot move onto rejection. Saving appears in the initiating action, with submission guards and actionable errors.

Create-and-name and group associations share the existing canonical transaction. Only the auditioned anchor and compatible exact aliases become confirmed; other group members retain explicit named associations awaiting individual confirmation. All original evidence remains available for stale-write checks and group association, including hidden short or unavailable members. Optional named-association provenance and Undo receipt/contact fields extend existing records; old records decode without inventing confirmations. Undo validates the exact owned action and protects later contact or recording use. Expected evidence is checked inside the canonical queue, and receipts are captured before yielding projection refresh.

Rejection applies to one sample-person pair rather than banning that person from other samples. Confirming a saved-speaker excerpt no longer writes a whole-speaker decision. Reassignment records rejection of the previous identity; returning to it removes that rejection. Ignore Sample excludes the audio from review and profiles without deleting the recording. Remove Assignment clears compatible exact aliases atomically, keeping recognition profiles, transcript projection, and review presentation consistent. Different explicit identities remain separate.

### Evidence selection and transcript context

Review ranking is separate from conservative automatic recognition. It uses compatible embeddings, plausible similarity, boundary/ambiguity ordering, recording diversity, and redundant-excerpt removal. Explicitly named pending samples bypass acoustic sampling so every associated excerpt remains actionable. Fixed anchors can propose joins within one recording/source, while individual samples remain correctable.

Exact source/file/revision/support-span identity collapses duplicate presentation and model evidence without deleting provider records. Effective human decisions prevent regenerated aliases resurfacing; compatible aliases receive one atomic decision and Undo snapshot. Genuinely conflicting identities remain distinct. Unavailable confirmed evidence can inform a profile but cannot become a playback question. Named questions are omitted from visible unnamed queues while linked evidence is retained.

`VoiceSampleTranscript` resolves physical sources and intersecting support spans, including disjoint excerpts and saved track ordinals. It does not borrow simultaneous text from another source or fabricate alignment. Asynchronous transcript loads have request/library guards, and highlighting requires the matching playback excerpt. Native word offsets drive highlighting; other text remains plain below identity controls.

### Compact context and native layout

Chooser meeting titles and dates load from existing index metadata and publish with the queue. Both named and unnamed rows show the newest meeting represented in pending samples, using meeting dates rather than evidence extraction dates. Known dates precede missing dates, ties are deterministic, and context advances when that meeting has no pending samples. Long labels truncate with full help/accessibility text. Meeting labels use pale blue; named-person labels reuse the stable speaker palette.

`LibraryView` retains a stable structural detail pane for `HSplitView`, with person-scoped identity inside it. This prevents selection from replacing the native pane while preserving draft/loader resets. Width restoration retains the earlier per-page, per-sidebar-state preferences and explicit drag persistence. The intermediate workaround that suppressed restoration on sidebar toggles was removed after final review: stable pane identity fixes selection jumps independently, so the original adaptive width contract remains intact. Explicit alternate data directories disable shared Keychain reads, writes, and deletes, preserving trial credential isolation.

Final integration review found that unified Open Recording navigation had dropped the selected transcript target. The integration correction restores that target through both library and person entry points. The 25-test focused navigation/session/context/bar suite, formatting lint, and isolated release build passed after this correction.

## Reasoning and superseded approaches

One person-oriented flow preserves efficient repeated confirmation and makes identity, reference evidence, and corrections consistent. Snapshot ownership fixes empty entries and mismatched summaries at their source; another count calculation or dismissal preference would retain the lifecycle defect. Deduplication resolves physical audio and human decisions while preserving provenance.

Earlier trials reserved a separate saving row; the final design moves progress into the clicked button. Dates first shared the title line; the final metadata line places date/start time before excerpt range and duration. The initial transcript design highlighted segments and explained passage timing; the final design highlights only saved word timings and removes that explanation. Early compact rows omitted titles, then showed the first displayed sample’s meeting; the explicit prioritization request supersedes both with the most recent pending meeting for named and unnamed people. Candidate ordering and initial sample selection are unchanged.

The separate Identify People card/list implementation was an intermediate revision and is retired. A representative sample may guide acoustic grouping, but it does not choose the initial displayed sample. The screenshot with identical ranges and Pause indicators established duplicate evidence/indicators; it did not establish that multiple streams were playing. Native split-pane identity was corrected after a failing regression rather than imposing another fixed width.

## Independent review

Multiple source reviews and Claude Code Opus 5.5 passes examined architecture, lifecycle, and previous reasoning. Accepted findings addressed candidate-load errors, autocomplete, stale writes, profile wording, repeated hydration, unnamed eligibility, overlapping queues, summary consistency, model-update starvation, audio invalidation, retry recovery, person-button recovery, stable action slots, centered saving indicators, skipped-sample actions, refresh deduplication, newly arrived work, and reference descriptions. Canonical naming/Undo reviews checked atomicity and concurrent edits. The initial single-record Clear semantics were superseded after final review exposed disagreement between effective presentation and stored recognition evidence. A harmless old dismissal preference remains inert rather than introducing a cleanup migration.

The final whole-thread Claude Code review explicitly used `claude-opus-5-5` with high effort. It found the canonical naming, guarded Undo, concurrent-edit checks, snapshot counts, exact-audio decisions, and restored recording handoff sound. Accepted findings restored maintenance access after review closes, retained the earlier sidebar-specific widths, added completion refresh, aligned reference-summary deduplication, made correction of suggested identities consistent, stabilized transcript loading against decision-only updates, and corrected documentation.

**Manage Samples…** is a secondary native list reached from Review Library and person Voice Samples. It preserves access to ignored and unavailable evidence, neutral assignment removal, separating/combining selected samples, and guarded durable Undo. These operations reuse canonical transactions and expected-evidence checks. The primary listening flow remains unified. Synthetic filtering and persisted reopen/restore/Undo/clear tests cover recovery beyond a review session.

The review’s proposed generic voice-similarity rejection was not adopted: pair-specific corrections intentionally avoid banning a person from unrelated legitimate excerpts. Unnamed ordering and further hydration/polling optimization remain measured follow-up opportunities rather than correctness claims. Automatic cross-recording discovery and noise filtering retain the limits below. The unused historical voice-sheet width preference is inert, not a second layout system. The follow-up review also identified alias-clear consistency, refresh after naming, and recovery after later edits. Clear now applies to compatible exact aliases; refresh follows the newly named person while retaining original evidence for Undo; maintenance supports naming cleared or rejected samples after reopening. Undo Library Change states its global scope and requires a durable action token. Persistence, projection, profile, refresh, and Undo regressions cover these corrections. A further pass corrected inherited clear flags and transcript projection for conflicting confirmed identities, and made create-and-name restore explicitly selected ignored or cleared samples while preserving whole-group exclusions. The final Opus pass found no remaining correctness blockers. Clear removes the selected evidence: other overlapping confirmed evidence may still assign the transcript. Unconfirmed conflicting claims can inherit the clear and leave review, while raw maintenance retains their stored status for inspection.

## Validation

| Stage | Recorded evidence |
| --- | --- |
| Initial core and revision | 142 tests across 39 suites, then 161 across 43 suites; canonical writes, pair-specific rejection, projection, profile evidence, grouping, deferred playback, persistence, and concurrency. Initial sandbox-only audio/Trash failures passed under the permitted execution environment without production workarounds. |
| Unified review and snapshot lifecycle | 177 tests across 44 suites, then 190 across 46 suites; source-specific transcript, native timing, alias decisions, hydration, model coalescing, immediate invalidation, deletion, and audio replacement. A provider-ID assumption was replaced with assertions for distinct audio, retained evidence, and restored decisions. |
| Bar recovery | Six shared-snapshot tests and three hosted lifecycle tests passed for read ownership, cancellation/retry, and remount after evidence changes. Same-revision success and person-button recovery also received source review. Unsupported hosted accessibility assertions were removed rather than using private APIs. |
| Final trial follow-up | 190 tests across 42 suites; nine divider/persistence tests, then all 17 session tests after the skipped-name fix. The native divider test reproduced an 85-point jump before the stable-pane fix and passed afterward. |
| Astra 6.1 prioritization | Five tests across two suites passed for newest-meeting context, pending removal, deterministic fallbacks, and bar lifecycle. |

Formatting, lint, whitespace checks, and release builds passed throughout the delivered trials, with macOS 26 minimum and SDK 27. Packaged trial and Preview signatures passed strict verification. Later successful synthetic captures superseded earlier `cgWindowNotFound` desktop-inspection blocks. Runtime checks verified light/dark bar placement, matching counts, zero-candidate disabled person actions, compact rows, newest-meeting chips, first-row selection/autoplay indicators, identity above transcript, unnamed double-click naming, advancement, completed-row retention, correction controls, guarded disabled slots, and recording navigation closing review with playback paused. Completing named work updated both bar and chooser to unnamed work alone.

Synthetic actions finished too quickly to inspect transient save-spinner appearance; long-list scrolling under sustained review and real-audio recognition quality were left to user transition testing. An earlier keyboard check reached Review Library with Tab but found Space intercepted by global playback and Return did not activate it; no later recorded runtime check establishes keyboard activation. The user subsequently accepted Astra 6.1. Final master integration passed 25 tests across four suites, lint, whitespace checks, and an isolated release build. The first remediation run passed 211 tests across 48 suites; the next passed 214 across 48 suites, with lint and release builds. Synthetic after-change capture verified the maintenance layout and All/Ignored filtering. Open Recording opened the selected recording’s Transcript tab when text was unavailable. The final recovery suite passed 216 tests across 48 suites. A fresh synthetic build verified tinted editable labels and disabled legacy Undo, then created a person for an ignored sample and successfully undid the change back to its original ignored identity. This establishes the actual naming/recovery interaction in addition to persistence tests. Final formatting lint, whitespace checks, and the isolated release build passed (macOS 26 minimum, SDK 27); the existing toolchain search-path warnings remain documented below.

## Technical debt and limits

- Review heuristics remain uncalibrated: similarity floor 0.55, an automatic 48-sample selection allowance, and boundary/ambiguity/diversity weights. Acoustic joins search at most 64 fixed anchors per recording/source at an initial 0.95 threshold; overflow stays separate. These bound review work without claiming calibrated identity probabilities. Evaluate against reviewed recordings, including full-library scale and cross-recording discovery, before changing recognition policy.
- Generalized noise suppression is not implemented. Exact ignored audio remains excluded across regenerated IDs, but one ignored excerpt does not justify suppressing similar legitimate speech. Add measured speech-quality/overlap metadata and separately evaluated filtering before using noise feedback broadly.
- Tentative review scores may read representations updated at different moments; a coalesced refresh follows. Human decision metadata remains strictly validated. External filesystem audio changes require explicit Refresh; in-app changes invalidate automatically. Existing compatibility query methods delegate to the shared store infrastructure.
- Historical dismissal preferences are harmless unused values. Optional provenance and Undo fields are durable extensions of existing records, not a parallel persistence model. No temporary duplicated UI or schema migration is retained.
- Toolchain linker warnings remain for absent Command Line Tools framework/library search directories. Builds link and signatures verify; no new API deprecations were observed. Repair/select a complete developer-tool installation and revalidate rather than suppressing application diagnostics.

## Trial data and delivery

Comparison builds use separate identities and explicit data directories, with remote providers disabled and pending copied tasks omitted. Private inputs, packaging scripts, backups, app bundles, source snapshots, and validation logs live under ignored `tmp/people-review-trials`; none belongs in the commit. The initial repeatable fixture contains twenty meetings and its original confirmed references. Requested resets restore that fixture while backing up tested states; they do not erase the main library. Astra 6.1 shares the Astra 6 trial data directory and must replace it after quitting the older trial. Subsequent startup-CPU reset left the trial closed for the user to launch.

The user approved committing and pushing. Integration is validated on master; unrelated repository instructions and sidebar experiments are excluded. Both macOS 26 and macOS 27 preview release jobs passed for commit `870ec2e` ([CI run](https://github.com/rankun203/gday-meetings/actions/runs/39587221625)).
