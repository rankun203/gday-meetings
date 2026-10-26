---
title: Speaker reference dataset results
date: 2026-10-26
status: not-run
scope: reference-quality-resource-cost-and-reproducibility
---

# Speaker reference dataset results

## Findings

No dataset capture, model inference, paid provisioning, or audio upload has run for this experiment. The detailed construction plan is ready for another agent. Teacher quality, cost, repeatability, and the benefit of execution optimizations remain unmeasured.

The motivating listening feedback found different clustering settings preferable in different meetings, with some configurations merging speakers and others leaving substantial speech unresolved. These observations motivate a common audited reference; they do not establish a quantitative ranking.

## References

[VibeVoice-ASR](https://huggingface.co/microsoft/VibeVoice-ASR) provides speaker-attributed long-form transcription. [pyannote](https://www.pyannote.ai/benchmark) publishes diarization benchmarks for its models. These are complementary proposal sources; neither establishes cross-meeting identities or guarantees correct labels on this library. [Runpod pricing](https://www.runpod.io/pricing) informs provisioning estimates; actual charges must be reconciled per run. Detailed protocol and source links are in [PLAN.md](PLAN.md).

## Experiment setup

Planned pilot: two or three complete meetings around ten minutes each, independently copied from the main library. Selection is pending. Existing candidate outputs are excluded from teacher inputs. Full recordings, timing maps, immutable teacher responses, reviewed annotation events, and release manifests remain in ignored private storage.

Two proposal sources: pinned VibeVoice-ASR on Runpod and an explicitly selected pyannote commercial model. The user has authorized both services; Runpod credentials are available in the app's local environment file. pyannote access and a numerical spending ceiling remain pending. No credential values were read during planning.

A verified reference contains explicitly human-audited regions. A provisional reference contains machine-generated labels and unresolved evidence. Report scores against these separately. Exact execution equivalence means equal normalized text, boundaries, and speaker partitions after arbitrary speaker-ID alignment; aggregate score similarity is insufficient.

## Pilot and optimization matrix

| Run | Meetings / audio hours | Model and runtime revision | Cold / warm time | Peak VRAM / RSS | Total billed cost | Exact equivalence | Audit result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| VibeVoice baseline | Pending | Pending | Not measured | Not measured | Not incurred | Repeatability pending | Pending |
| VibeVoice optimized | Pending | Pending | Not measured | Not measured | Not incurred | Pending | Pending |
| pyannote commercial | Pending | Pending | Not measured | Provider counters may be unavailable | Not incurred | Raw response retained | Pending |

## Reference quality and release status

| Measure | Result |
| --- | --- |
| Captured meetings | 0 |
| Teacher-labeled audio | 0 hours |
| Verified audio | 0 hours |
| Random agreement audit | Pending |
| Targeted disagreement audit | Pending |
| Cross-meeting identity audit | Pending |
| Frozen split / release manifest | Pending |
| Medium/long-recording validation | Pending |
| Committed paid resources | None |

## Limitations

Teacher agreement is not human verification. A short pilot cannot establish long-context quality, GPU capacity for longer recordings, or cost scaling. Exact repeatability across inference engines and hardware is unproven. Cross-meeting identity links need separate review. Targeted disagreement audits cannot estimate library-wide error without representative sampling. Dataset expansion and candidate ranking must retain these distinctions.

Update this document by replacing pending entries and integrating findings into the relevant sections. Record actual commands and revisions; do not append conflicting progress narratives or describe proposed measurements as completed results.
