---
title: Compare local and remote final speaker attribution
date: 2026-10-15
status: validated
scope: diarization-experiment
---

## Problem

The deployed worker returns speaker assignments on words, not raw acoustic turns. Comparing these outputs as raw diarization accuracy would conflate transcription, alignment, and speaker assignment differences.

## Implemented solution

`experiments/runpod-output-comparison/compare.py` compares local timed text spans with explicit remote word labels per source track. It does not reconstruct acoustic turns or inherit segment labels for unlabeled words. A time-interval sweep separately measures timed coverage, attributed coverage, unresolved intervals, multiple-speaker output, and simultaneous assigned/unresolved output. Duplicate intervals for the same speaker do not inflate duration.

A maximum-weight one-to-one mapping matches anonymous labels using mutually single-speaker time. Agreement is reported only on that denominator, alongside coverage and ambiguity. The output includes differing time windows for listening review without copying transcript text into the repository. Blank labels remain unresolved.

Results are restricted to temporary directories or the experiment's ignored `.local` directory. New result files use mode 0600 and new directories use mode 0700. Output cannot overwrite a named input. The tool makes no network requests and does not modify the library.

The offline `review.py` page presents final passages in two synchronized cards with one audio player. Method names are hidden behind A/B labels until revealed. Anonymous speakers use consistent neutral numbers and colors across both outputs. The review asks about speaker assignments rather than transcription wording. It marks inferred and unresolved labels, separates unplaced remote text, and offers opening windows, five uniformly spaced windows per track, differing windows, and arbitrary start/duration input. Exact matching preserves the original remote text spacing, including character-tokenized English and Chinese; unmatched text preserves provider tokens with explicitly marked reconstructed spacing. CJK and punctuation tokens are joined naturally, and consecutive single-letter tokens are joined for readability; this does not claim exact source correspondence.

Reviewers can choose A, B, Same, or Unsure, add issue categories and notes, advance to the next unreviewed window, and export feedback. Local persistence and exported feedback retain the audio hash, window, sampling type, hidden method mapping, and whether method names were revealed. The feedback format explicitly identifies the results as listening preferences rather than ground truth. No transcript text or audio is included in the feedback export. Audio comes only from hash-verified prepared files referenced by relative paths. Embedded text is JSON-escaped and rendered with DOM text nodes; the page disables network connections. No acoustic timeline is reconstructed.

## Reasoning

Final-output agreement supports a controlled listening comparison, but it is not diarization error rate or correctness. Mapping is optimized on the comparison itself; transcription timing differs between engines; inferred local labels are included. Those limitations are explicit in generated results. The comparison relies on the separately verified copied-audio manifest for source identity.

## Technical debt

None. Absence of independently annotated ground truth limits the experiment's conclusions; no accuracy claim is made.

## Validation

Nine synthetic tests pass: global label mapping, label permutation, unequal speaker counts, duplicate and overlapping intervals, separate unresolved coverage, disjoint time, missing word timing, stale local text, unknown tracks, invalid intervals, blank labels, private output permissions, and input-overwrite rejection. `git diff --check` passes. Six additional review tests cover script-injection text, source/hash mismatches, explicit label grouping, missing timing, exact Chinese and English spacing, unmatched-token readability, and the versioned feedback contract with blind method mappings, sampling types, and reveal state. All 22 experiment tests pass together, including the submission runner's synthetic tests. Both JavaScript syntax checks pass.

The existing page screenshot was inspected before the redesign: long text columns and ordinary controls made review progress and decisions difficult to track. The implemented layout uses a compact sticky audio toolbar, paired cards, and a prominent review panel. The private page was regenerated using the deployed-worker response and the latest validated local projection. Root browser validation passed persistence and reload, JSON export, reveal state, next-window sampling, playback, seeking, and stopping, with no JavaScript errors. Screenshot review found unreadable separators in unmatched character tokens; the fallback was revised to reconstruct readable spacing without claiming source correspondence. Final screenshot validation confirmed readable text in both columns and controls matching the design.


All 22 comparison tests and three tuning-harness tests passed. Human speaker-correctness judgments remain pending.
