---
title: Diarization-driven transcript projection
date: 2026-10-14
status: implemented
scope: macos-audio-analysis
---

# Problem

Saved diarization assigned a label only when one speaker covered most of an existing recognition row. Recognition rows could contain silence or several voices. Saved transcripts also discarded available timing within each row, preventing safe regrouping around acoustic speaker turns.

# Implemented solution

The new timing representation retains exact UTF-16 text spans and timing granularity. Apple recognition runs and remote aligned words remain distinct; missing timing is represented by gaps in otherwise usable timing. Transcript rows retain independent analysis track identity.

A saved transcript projector assigns supported timed spans to acoustic turns and groups across recognition-row boundaries. Coarse spans that overlap several speakers and untimed lexical gaps remain unresolved. Source anchors preserve the original characters across repeated splitting and merging; display separators are recorded separately. Existing manual assignments and changed text remain intact. Consecutive unresolved timed spans are grouped only within the same original row and acoustic gap or identical ambiguous interval set. Contiguous source anchors and boundary checks prevent grouping across speaker turns; punctuation retains its original timing and remains unresolved.

Recorded analysis contracts separate transcription from diarization. Existing adapters validate requests, audio revisions, and normalized output at their boundaries. Immutable transcription artifacts and diarization bindings accompany canonical publication and history. Compatible history can restore a different grouping when the exact source characters, timing, track, and session still match.

Saved transcript presentation now composes a recognized passage with neighboring unresolved continuation until a sentence ends or another voice starts. Canonical rows, speaker uncertainty, timing, source anchors, and downstream summary/export inputs remain unchanged. Native sentence tokenization and a decimal-continuation check avoid treating every period as a sentence boundary. Interleaved tracks, sessions, manual assignments, and other-voice acoustic overlaps remain boundaries.

Compound display rows retain their constituent IDs and text ranges. Playback highlights only actual constituent intervals and text clicks seek to the clicked constituent. Editing or speaker assignment expands the passage to canonical rows before invoking the existing action. Expansion remains for the current transcript selection so refreshes cannot hide an active edit; reopening the transcript restores the reading layout. Accessibility notes unresolved text without adding visual controls.

# Reasoning

Diarization determines speaker turns. Recognition supplies text and timing; its original row boundaries must not limit diarization. The implementation does not lower whole-row attribution thresholds or invent word times inside a coarse recognition run. Existing durable task scheduling and canonical transactions remain the publication mechanisms.

# Technical debt

- Legacy transcripts without timing retain their existing whole-row fallback. Their original word timing cannot be reconstructed from saved rows. A new transcription revision supplies timing; an alignment-only provider remains future work.
- Edited passages without valid alignment and manual passage assignments remain intact. This is conservative preservation, not complete source-anchored edit replay across arbitrary new boundaries. A future alignment and edit-operation layer can reproject those passages safely.
- Voice-library ingestion retains its existing separate persistence step before canonical transcript publication. A later canonical failure can leave review examples without published labels. Stage voice-example ingestion in the canonical transaction to remove this retained compromise.
- Live adapter migration is bounded to supported existing adapters. Declaring a future capability does not make an unimplemented provider selectable. Streaming identities remain session- and epoch-scoped.

# Validation

Synthetic checks cover cross-row grouping, within-row speaker changes, repeated projection, source anchors, coarse timing, overlap, manual assignments, missing words, and Chinese text. Provider tests cover missing timing, repeated words, invalid timestamps, and track mapping. Immutable-source and history tests cover changes in text, audio, timing, and source identity.

Real-app visual review found that unresolved timed tokens appeared as separate rows. A focused correction groups compatible unresolved tokens without assigning speakers; synthetic cases cover punctuation, exact timing and source anchors, repeated projection, manual protection, and intervening acoustic boundaries. Parent validation passed, including exact reconstruction of every source character in the final saved result.

Parent review corrected persistence decoding, request admission, uncertainty propagation, source anchors, and compatibility with older saved results. The expanded regression run passed 166 tests in 27 suites. An isolated release build passed; the toolchain still reports two missing Command Line Tools linker search paths. No deprecated API warning remains in the changed code.

The first real-app transcription request exposed an option mismatch between admission and capability validation before analysis or transcript replacement. Admission now shares a tested request builder and validates the supported combined-diarization option. The follow-up run passed 42 tests in five suites, and the updated isolated release build passed. The authorized local transcription and diarization then completed. Private source metadata was backed up locally; no private meeting content was copied into the repository. The matched-input DiariZen experiment is documented separately in `experiments/diarizen-comparison/`.

The real-recording review retained 5,031 timed spans across 94 source rows. Initial projection attributed 4,460 spans (88.7%); source-anchor verification confirmed every original UTF-16 character occurred exactly once. The previous transcript remains in history. Screenshot review exposed one-character unresolved rows, and grouping adjacent unresolved spans with identical acoustic evidence reduced the projection to 651 rows without changing attribution. Short unresolved spans at acoustic boundaries remain visible for user review. Coverage is not an accuracy measurement.

Final grouping validation passed 18 release tests in three suites. The isolated release build, formatting, and diff checks passed. The updated review app reopened the real library and completed another diarization; the result was inspected in the app. Local model readiness initially required opening Service Providers before Diarize enabled; no model download or settings change was needed. This startup readiness behavior remains outside this change. The user was invited to assess actual speaker changes; higher coverage is not presented as proof of accuracy.
