---
title: Preserve native transcription timing for speaker projection
date: 2026-10-15
status: validated-awaiting-user-transcription
scope: macos-transcription-and-diarization
---

## Problem

Saved transcripts without text timing constrain speaker assignment to entire recognition passages. Timed passages can also lose labels when a word straddles an adjacent speaker boundary. Apple transcription already requested audio time ranges, but normalization reconstructed offsets by searching text; an invalid duration could discard the whole timing object. This is a code-path risk, not a proven explanation for historical transcripts without timing.

## Implemented solution

- A shared Apple transcription adapter retains exact UTF-16 offsets from the attributed result, preserving valid neighboring intervals when another run has no usable timing. It keeps every text character. The live and recorded paths both use it.
- Native intervals containing exactly one lexical token are marked as word timing using Natural Language tokenization. Multiword intervals remain runs. No interval is divided or interpolated. This distinction lets the projector apply word-boundary rules without pretending a whole phrase has word alignment.
- Optional exact timing survives phrase checkpoints, paragraph grouping, segment serialization, conversion back to live phrases, and live fragment trimming. Historical checkpoints remain readable. Changed text does not reuse stale native offsets.
- Projection can assign a precise word when one adjacent turn covers at least 75% of it, provided no different voices overlap within it and the word lasts at most 1.5 seconds. A gap is filled only when the same speaker brackets it within 200 milliseconds. Both cases retain uncertainty. Coarse mixed-speaker runs, genuine overlap, unsupported silence, and manual assignments remain protected.
- Remote response normalization retains valid word timing around invalid duration values, advances text matching through those values, and stops at an unmatched token rather than guessing a later offset.

## Reasoning

Fix timing preservation before changing the acoustic model. The recorded native and remote routes share exact text/timing semantics, while source timing remains immutable through speaker projection. Partial evidence is useful without claiming that untimed words are aligned. Attribution thresholds are deliberately bounded and are not a substitute for comparing acoustic outputs on identical input.

Apple documents time ranges on attributed runs and permits runs without timing: [SpeechAnalyzer presentation](https://developer.apple.com/videos/play/wwdc2025/277/) and [time-range attribute lookup](https://developer.apple.com/documentation/foundation/attributedstring/rangeofaudiotimerangeattributes(intersecting:)). The adapter retains that granularity instead of inventing lexical timestamps for coarse runs.

## Technical debt

None added. Historical transcripts without timing remain unchanged at the user's request. They require a new user-initiated transcription for a word-aligned comparison; this change does not migrate or regenerate saved content.

## Validation

Synthetic tests cover repeated words with an untimed occurrence, zero-duration punctuation, Chinese text, UTF-16 emoji offsets, coarse native runs, paragraph merging, checkpoint/segment round trips, live slicing, stale text, adjacent speaker boundaries, simultaneous speech, bounded gaps, and projection idempotence. Root review corrected whitespace trimming and stale timing reuse. All 53 release tests in eight suites passed in 5.047 seconds. The opt-in Apple recorded-transcription test passed in 1.849 seconds using generated speech, Opus decoding, native timing, and actual transcript persistence. The copied-artifact projection preserved exact text, source anchors, and all 11,690 timed spans; attributed spans increased from 10,162 in the saved prior projection to 10,176 with identical acoustic input. Coverage is not accuracy. Formatting and diff checks passed. Isolated `make build-macos` passed in 212.55 seconds and the copied review app passed signature verification. Two existing linker warnings reference missing Command Line Tools search directories; no new deprecation warning was reported. No main-library content was changed.

Read-only baseline inspection found that the new remote request disabled diarization. Its source artifact contains 251 rows, including 192 with 11,690 timed word spans; 59 rows have no timing. The later projection uses the same 960 local acoustic turns as the earlier local run. The original local source has 394 rows without timing. The normalized remote artifact does not retain the raw response, so missing upstream timing cannot be distinguished from earlier adapter rejection. This is an alignment/projection comparison, not a remote-versus-local acoustic accuracy result. The user will initiate a new local transcription after validation; acoustic tuning is deferred.
