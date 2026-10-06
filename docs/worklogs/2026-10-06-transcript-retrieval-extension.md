---
title: Transcript retrieval benchmark extension
date: 2026-10-06
status: evaluated-with-limits
scope: retrieval-evaluation
---

# Problem

The existing comparison does not measure recent compact multilingual transcript encoders against its strongest text baseline.

# Implemented solution

Extend `experiments/audio-retrieval/` with pinned Granite 97M/311M, Harrier 270M/0.6B, and Qwen3 Embedding 0.6B runs. Merge findings into the existing `RESULTS.md`. Preserve original private artifacts and store extension outputs separately in ignored storage.

# Reasoning

Reuse the same queries, passages, and evidence labels for a paired comparison. Fix task instructions before scoring. Measure one model at a time with synthetic warmup, synchronized Metal inference, and sampled process and device memory. Remeasure the Jina text path under the same protocol.

# Technical debt

Retained: the corpus has only 50 selected queries and 150 passages, with nonexhaustive evidence labels and no held-out split. This limits conclusions about production retrieval. Remediation: evaluate finalists on a larger independently labeled library. Native conversion and energy measurements remain outside this Python screening experiment; measure them before app adoption.

# Progress

- Reviewed the existing benchmark, writing guide, and publisher preprocessing specifications.
- Added a text-only encoder runner and optional text-run inputs to the comparison script.
- Completed the five candidate runs and the Jina text-only resource reference, with 200 embeddings per model. Granite 311M and Qwen matched Jina's first returned passage on all 50 queries; Granite also matched its original-positive rank for every query. Granite 97M reached 92% evidence hits first and 98% within ten.
- Extended the blinded pool by 164 judgments to 1,602 total pairs. One new pair supplied partial useful evidence. Recomputed extension nDCG against the expanded pool while retaining the original report's pool and outputs.
- Merged methods, checkpoint references, language slices, paired uncertainty, resource tables, and recommendations into the existing `RESULTS.md`; documented reproduction commands in `README.md`.
- Sequential float32 Metal runs measured a 623 MB Granite 311M checkpoint and 15.1 ms median query encoding, versus 1.192 GB and 32.4 ms for Qwen. Recorded timing tails, loading RSS, separate Metal allocations, and the limits of synthetic warmup. These are Python observations, not native-app estimates.
- CPU/Metal checks passed for three queries and three passages per model: 36 probes, minimum cosine above 0.99999999999. Jina text-only loading exactly reproduced its original transcript score matrix and complete rankings.
- Nine synthetic tests passed, including input-fingerprint rejection and preservation of original comparison outputs. All pooled judgments passed completeness and schema checks.
- Final checks passed for Markdown metadata, local links, whitespace, and accidental inclusion of private full text or identifiers. Original evidence metrics remain unchanged. Archived the final experiment source beside the private run artifacts.

# Notes

One public checkpoint download required a transport retry. Successful model runs emitted no deprecation warnings; unauthenticated download notices remain. No private data was uploaded. No Swift, UI, app model, or index changed, so a macOS release build was not applicable.
