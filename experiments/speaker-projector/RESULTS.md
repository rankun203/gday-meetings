---
title: Speaker projector validation
date: 2026-10-08
status: experimental
scope: export-validation
---

# Findings

Thirteen synthetic export tests and a WAV-to-Parquet/JSONL smoke export pass. They verify mappings and diagnostic separation; they do not establish speaker accuracy. No meeting-specific identifiers, vectors, audio, or names are part of this report.

# References

Apple's [Embedding Atlas data formats](https://apple.github.io/embedding-atlas/data-formats.html) support Parquet, JSONL, and playable WAV data URLs. Its [command-line interface](https://apple.github.io/embedding-atlas/tool.html) accepts precomputed projection coordinates and neighbors, allowing the original voice embedding space to remain authoritative for distance calculations.

# Experiment setup

The exporter consumes production evidence and cluster assignments, preserves separate historical reference roles, and creates cosine UMAP coordinates with seed 42. Exact neighbors remain in normalized 256-dimensional space. Historical interval overlap supplies context, never speaker ground truth. Named-reference similarity excludes overlapping same-source audio and remains a diagnostic.

# Results and limitations

The distance comparison preserves all 272 rows and evaluates 36,856 unique unordered pairs, including references. Metric MDS improves distance-rank correlation from 0.688 (UMAP) to 0.728 and reduces scale-adjusted stress from 0.522 to 0.340. Stress fits one global scale before measuring the normalized residual; it is not an identity accuracy metric. Both maps remain lossy. The exact cosine heatmap and linked sample inspector expose the original scores. Seven additional synthetic comparison tests pass, bringing the projector suite to twenty tests.

| Check | Result |
| --- | --- |
| Historical context does not assign replay identity | Pass |
| Unconfirmed excerpt does not become a named reference | Pass |
| Overlapping reference audio is excluded | Pass |
| Version and vector validation | Pass |
| Cluster membership and reference timestamp integrity | Pass |
| Capacity trust and union coverage | Pass |
| Synthetic audio playback payload and file export | Pass |
| Integrity guards remain active under optimized Python | Pass |
| Required artifact hashes and source/identity collision checks | Pass |
| Null capacity and nonfinite window bounds | Pass |
| Atomic export cleanup after failure | Pass |
| External WAV byte/hash preservation and loopback-only URLs | Pass |

A complete private two-source recording was reconstructed with the validated production policy. Both replays had stable model/source/binary hashes, no gaps, and no extraction failures. The current optimized consolidation exactly reproduced the frozen microphone result. The source-separated combined result contains 252 fresh embeddings, 13 trusted local-label units, nine provisional clusters, and 25 selected examples. A separate reference role contains 20 re-extracted historical excerpts; nine confirmed excerpts cover five people. No speaker activity was detected on the second source.

The reconstruction assigns 789.99 speaker-seconds overlapping sampled audio and 1,882.50 through local-label continuity, with 30.89 unresolved. Speaker-seconds include overlap and are not an accuracy metric. Against this limited meeting-specific reference set, no fresh sample passed the existing 0.85 cosine and 0.08 margin gate; the highest independent named-reference cosine was 0.7631. Names remain diagnostics, not applied assignments. No worker output or independent complete speaker reference was available for this particular recording, so these results do not establish DER or improvement over the worker.

All 272 exported audio payloads have the expected sample rate, channel count, and duration; vectors are normalized. Browser checks confirmed 272 points, readable cluster names, nine first-choice representatives after filtering, successful excerpt playback, and 15 nearest-neighbor results. Visual review caught and fixed case-insensitive database column collisions and short-line simplification hiding activity intervals. The interval view merges only touching/overlapping same-label spans and disables line simplification; it does not fill gaps. The viewer uses loopback URLs for hash-named WAV files to avoid slow queries over inline audio. Its Parquet decreased from 36,825,763 to 822,848 bytes; all 272 audio hashes are preserved. The canonical export remains self-contained. Final browser rechecks rendered all 272 points and the populated table without a loading state; a loopback WAV played with the expected duration and no media error.

The replay test's Date-based duration differed from its monotonic driver duration during the second source run. Runtime claims must use the driver clock; this experiment makes no performance comparison from that run. A two-dimensional plot cannot validate speaker identity, and historical transcript rows may contain the original labeling errors under investigation. The exporter does not claim diarization accuracy or modify meeting data.
