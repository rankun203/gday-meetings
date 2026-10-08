---
title: Compare speaker embedding distances
date: 2026-10-08
status: complete
scope: local-speaker-projector
---

# Problem

The UMAP view made distinct voice groups appear adjacent, encouraging interpretation of screen distance as voice similarity.

# Implemented solution

Added a local comparison page with UMAP, metric MDS, and an exact cosine heatmap. A shared inspector connects sample and pair selection to exact scores, nearest neighbors, and two audio players. Overlapping source excerpts are excluded from neighbors by default. Atlas links to the comparison page through navigation that reserves its own height.

# Reasoning

MDS minimizes distance distortion without using speaker names or cluster labels. The heatmap retains exact similarities when no two-dimensional projection can preserve them. The generator binds sample identities, canonical audio bytes, source hashes, and output hashes; it uses local assets and retains all original evidence. A 1,000-sample limit bounds quadratic computation explicitly.

# Validation

Inspected and captured the original Atlas screen before implementation. Twenty synthetic tests pass, including scale invariance, row reordering, degenerate vectors, audio swaps, remote audio URLs, and MDS recovery. The private 272-sample comparison covers 36,856 unique pairs: UMAP distance-rank correlation 0.688 and scale-adjusted stress 0.522; MDS 0.728 and 0.340. These measure geometry, not speaker accuracy. Browser review checks the three views, pair scores, audio, and navigation. Saved meeting data and assignments remain unchanged.

# Technical debt

None added. The comparison is an inspection tool with an explicit dataset bound, not a replacement diarization algorithm. Two-dimensional distortion and sparse reference coverage remain documented analysis limits.
