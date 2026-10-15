---
title: Diagnose unresolved speaker labels and prepare reference annotation
date: 2026-10-15
status: awaiting-annotations
scope: isolated-diarization-experiment
---

## Problem

Blind listening feedback favors local microphone output but remote system-audio output. Local system speech often remains unresolved. In four flagged system windows, 25 unresolved timed spans have no acoustic overlap and 13 overlap one speaker but fail assignment. These are timing and coverage observations, not verified missed speech. Eight microphone notes identify remote noise pickup; one identifies local noise. Agreement with remote output is therefore insufficient as an optimization target.

## Implemented solution

Preparation is complete in `experiments/speaker-label-recovery/`. The offline annotation package combines development examples for both failure types, microphone noise controls, and fresh validation clips outside previously reviewed intervals. Original audio, source text, timing, and acoustic outputs remain immutable. Private inputs and generated artifacts stay in ignored local directories. No worker deployment, remote job, library mutation, or transcript adoption is authorized by this experiment.

The annotation design uses one audio player, bounded replay, neutral speaker reference clips, exact source context with highlighted targets, and a decision for each target. Decisions distinguish a reference speaker, another speaker, no speech, overlap, and uncertainty. Timing and missing-word flags remain separate from identity. Progress saves locally and can be exported and imported. Candidate predictions and development/validation partitions are hidden from the labeling UI. Exported feedback identifies immutable items and input hashes without including transcript or audio.

## Reasoning

Collect independent listening labels once for the prepared batch. Run diagnostic calculations and low-cost replay before asking the user to label; defer changes whose justification depends on those labels. Keep validation items out of threshold selection. Evaluate correct recoveries, wrong assignments, unresolved targets, and noise false positives separately, rather than treating additional labels as improvement. Do not infer silence solely from missing acoustic turns.

## Technical debt

No production shortcut or schema debt was added. Existing source timestamps and model-derived speaker reference clips are imperfect; reference clips are comparison aids, not verified identities. The UI must allow uncertainty, another speaker, overlap, and incorrect timing rather than forcing a model label.

## Progress and handoff

- Root: review experiment design, code, sampling, evidence, and browser interactions; maintain this worklog.
- Diarization agent: diagnostic extraction, immutable sample manifest, development/validation sampling, preparation script, synthetic tests, and experiment results.
- Annotation UI agent: offline renderer, per-target annotation contract, persistence/import/export, and synthetic tests.
- Existing baseline/dense experiment is complete: denser windows increased cost and reduced assignment coverage; production defaults remain unchanged.
- Existing feedback has 40 entries;39 have a preference or unsure choice, one has a note without a vote. All method names were hidden. Do not require a repeat of the previous review.
- Next dependency: user completes the new annotation batch. Then validate manifest/hash/target matches, score candidates, tune on development cases only, and evaluate the frozen validation set. Additional labeling is needed only if a later hypothesis introduces examples or identity questions absent from this batch.

## Validation

Nine synthetic tests passed. Root inspected the final generated screenshot, including numbered context highlights and precise target timestamps, and independently validated browser playback bounds, per-target decisions, hidden partitions, noise-control choices, autosave/reload, export/import round trip, invalid-batch rejection, and zero JavaScript errors. Static review checked native keyboard-accessible controls, incomplete judgments, strict imports, UTF-16 conservation, audio hashes, source granularity, and sampling separation. No Swift production code changed; no release app build was needed for this isolated HTML/Python preparation.

## Resume after labeling

The frozen page is `experiments/speaker-label-recovery/.local/review.html`; its manifest and diagnostics are beside it. The package contains 29 clips and 64 judgments: 26 flagged lexical targets, nine microphone speech-presence controls, and fresh unresolved/previously assigned validation targets. Twelve decoration-only spans remain in diagnostics and should receive deterministic attachment tests rather than identity annotations. Original totals remain 13 partial-overlap and 25 no-overlap spans; lexical counts are eight and 18 respectively.

When the user returns the exported JSON, validate its batch/input fingerprint, target IDs, clip identity, audio hashes, decisions, flags, and references against the frozen manifest. Do not regenerate the batch. Quarantine development labels with custom references into held-out material before fitting; exclude held-out labels referencing development material from independent evaluation. Report these exclusions and remaining denominators. Keep uncertainty, timing errors, and unusable references separate from identity correctness. Fit projection candidates on development labels only, preserve existing assigned controls, then score the frozen validation targets. Acoustic-stage investigation depends on listening evidence; final turns do not expose the internal segmentation/vote arrays, and zero-vote re-embedding changes identity rather than necessarily recovering coverage.

The next required input is the user's exported annotation file. No additional review round is necessary before scoring this batch. No labels have been inferred from the earlier preference votes.
