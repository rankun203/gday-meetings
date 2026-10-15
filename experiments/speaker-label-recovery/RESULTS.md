---
title: Speaker label recovery diagnostics and annotation preparation
date: 2026-10-16
status: awaiting-annotations
scope: experiment-results
---

# Findings

The four flagged system-audio windows contain 38 unresolved timed spans. Thirteen overlap one final acoustic speaker, but none has its midpoint inside that speaker's turn; their overlap covers 2.75%–48.90% of each span. Twenty-five have no overlap with a final acoustic turn. This explains the projector's lack of direct assignment, but does not establish whether the acoustic boundary or transcript timing is correct.

Of these 38 spans, 26 contain lexical text and 12 contain only punctuation or whitespace. The annotation batch asks identity questions for the 26 lexical spans. All 38 remain in diagnostics. Decoration-only spans require deterministic attachment/display tests, not human voice judgments. The 12 decorations have coarse `.run` timing; the 26 lexical targets have `.word` timing.

| Flagged span class | Lexical targets | Decoration-only spans | Total |
| --- | ---: | ---: | ---: |
| One acoustic speaker overlaps, midpoint outside | 8 | 5 | 13 |
| No final acoustic overlap | 18 | 7 | 25 |

No new inference or tuning was run. No acoustic-stage cause or recovery quality claim is supported yet.

# References

The pinned [projector implementation](../../apps/client-macos-swift/Sources/GdayMeetings/Core/DiarizedTranscriptProjection.swift) assigns timed text using saved acoustic turns while retaining unresolved spans. The experiment preserves original text offsets and timing rather than treating the rendered passage as a recognition unit.

FluidAudio at revision `21493f8dac5a97e65742e6ff26f42f164c2fda0f` exposes [prepare and cluster operations](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift). Its [prepared result](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/Diarizer/Offline/Core/PreparedDiarization.swift) publicly exposes counts, while segmentation and timed embedding fields are internal.

The [zero-vote reconstruction code](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/Diarizer/Offline/Utils/OfflineReconstruction.swift) already assigns speech-active frames without cluster votes through a cluster-zero tie-break. Re-embedding those frames can change identity; it must not be assumed to restore missing speech coverage. Final-turn absence alone is not evidence for enabling that option.

# Experiment setup

The batch uses the saved immutable native transcript, saved bounded projection, saved native acoustic turns, original reviewed-audio hashes, and the same private decoded audio prepared for the preceding ablation. No library files were modified. Prior feedback identifies development windows but is not treated as a gold speaker annotation.

| Batch component | Clips | Purpose |
| --- | ---: | --- |
| Flagged system unresolved text | 4 | Annotate all 26 lexical targets from the diagnosed windows |
| Microphone noise controls | 9 | Judge speech presence without inventing a transcript word |
| Fresh unresolved examples | 12 | Hold out matching failure classes from rule fitting |
| Fresh previously assigned examples | 4 | Detect regressions, two clips per source |
| Total | 29 | 64 independent target judgments |

Adjacent targets share a clip but retain separate answers. Neutral nearby references are provisional audio excerpts. Every assigned control has at least one usable-duration reference candidate; the listener may still mark it unusable. Fresh clips and references avoid all 40 prior feedback intervals and all development references. Sampling uses fixed hash ordering instead of selecting examples that favor a proposed rule. The private partition and category are removed from the review interface.

# Metrics and interpretation

Acoustic support is the union duration of final speaker turns intersecting the original timed text span. Coverage fraction divides that duration by span duration; midpoint coverage tests the projector's temporal anchor. These are alignment diagnostics, not probabilities or speaker accuracy. For no-overlap targets, nearest neighboring turn distance ranges from about 12 milliseconds to 14.13 seconds, so a single boundary-padding explanation does not cover every case.

Human responses will distinguish speech presence, speaker identity relative to provisional references, overlap, uncertainty, and timing errors. Coarse timing cannot support exact word-edge tuning. A reference marked unusable must not become an identity anchor. Before scoring exported custom references, check their intervals against private partition boundaries. Quarantine development labels whose custom references intersect held-out clips or references before fitting. Also exclude held-out labels whose custom references intersect development or previously reviewed clips or references from independent validation. Keep both exclusions explicit; do not import held-out identity evidence into fitting. Record exclusions and the remaining denominator. The held-out targets remain excluded from fitting and threshold selection; report their coverage and correctness separately after annotations arrive.

# Retained evidence and next instrumentation boundary

Saved artifacts contain immutable timed text and final acoustic ranges, but no segmentation arrays, local-speaker masks, embedding eligibility, chunk-to-cluster assignments, or frame vote sums. `OfflineDiarizerManager.prepare(audioSource:audioLoadingSeconds:progressCallback:)` returns a `PreparedDiarization` that can be passed to `cluster(_:)` repeatedly in memory. Its public fields provide embedding and segmentation-chunk counts only. `exposeChunkEmbeddings` can expose selected clustered embedding records after clustering, but does not expose segmentation or zero-vote evidence.

If annotations show a need for acoustic-stage diagnosis, add an experiment-only read-only dump inside the isolated pinned FluidAudio module. Capture segmentation frame offsets/activity, embedding eligibility, chunk assignments, and reconstruction speech counts/vote sums around labeled targets. The hook must preserve numerical operations and default configuration. Public API reuse alone cannot reconstruct these internal arrays from saved final turns. No such instrumentation or inference was run for this batch.

# Validation and limitations

Five synthetic tests cover UTF-16 source mapping, coarse timing preservation, partial/no-overlap classification, held-out/reference isolation, duplicate rows, invalid timing, and decoration exclusion. The generator reproduces the 13/25 diagnostic split and validates feedback/audio hashes. Annotation results are pending; the review interface has its own validation workflow.

This is one recording and a targeted development set plus a within-recording holdout. Selection is intentionally enriched for failures, so its raw error rate cannot estimate all-meeting accuracy. Final acoustic turns and transcript timing remain hypotheses until listening establishes what was spoken and when.
