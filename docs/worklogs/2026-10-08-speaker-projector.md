---
title: Export speaker evidence for Embedding Atlas
date: 2026-10-08
status: complete
scope: speaker-projector-experiment
---

# Problem

Speaker labeling needs sample-level inspection across a whole meeting, including voice vectors, cluster membership, playable excerpts, and historical review context. Historical channel names must not become assumed reference identities.

# Implemented solution

Added `experiments/speaker-projector/export.py`, `combine.py`, a standalone runner calling production consolidation, `atlas.py`, synthetic tests, and experiment documentation. The exporter produces private Parquet and JSONL with corrected version 2 vectors, seeded cosine UMAP coordinates, exact 256-dimensional neighbors, production representative ranks, source/window/timestamps, trust reasons, and WAV data URLs. Historical references have a separate role. Names require explicitly confirmed excerpt reviews; overlap with historical transcript rows supplies context only.

The local view combines an Atlas embedding projector with a separate interval timeline and a private process explanation. No app UI was changed. The existing Atlas screen was inspected before configuration; final checks compare the configured view with the intended readable clusters, filters, and playable examples.

# Reasoning

Reuse Embedding Atlas instead of maintaining a custom viewer. Keep projection distance separate from exact cosine distance. Named-reference diagnostics exclude overlapping same-source audio and never apply a person assignment. Validate typed-vector compatibility, complete membership, source hashes, and reference timestamps before export. Record input/output hashes and package versions. Source combination now requires complete artifact bindings, distinct source IDs, and no sample/local-label collisions, with explicit checks that remain active under optimized Python. Export rechecks inputs and audio after computation and publishes through an atomic directory rename; failures remove staging files. Null capacity means unreached capacity, while nonfinite window bounds fail.

# Validation

Thirteen synthetic tests and Ruff pass. A synthetic WAV-to-Parquet/JSONL export passed, including audio data URLs and provenance output. The README’s standalone production Swift compilation passed. Read-only viewer review confirmed row-order neighbors, historical label joins, production representative markers, source-separated timelines, and input rechecks. Documentation explains UMAP versus exact cosine, historical context versus assignment, the diagnostic score gate, and local-label continuity limits. The full private export contains 272 points, nine clusters, and 25 selected examples. All 4,080 neighbor indices and cosine distances were independently checked. Browser checks confirmed filtering, playback, and nearest neighbors. Atlas uses readable, case-distinct columns; the timeline preserves short intervals instead of allowing line simplification to hide them. The rendered private explanation separates activity coverage from identity accuracy and records that no fresh sample passes the current person-match gate against the limited historical reference set. A full-view recheck then exposed slow queries caused by inline audio payloads. The viewer now stores hash-named WAV files behind loopback-only URLs, reducing its Parquet from 36.8 MB to 0.82 MB; canonical exports remain self-contained. Exact audio hashes and loopback guards pass synthetic and full-data checks. Final browser rechecks rendered all 272 points and the populated table without a loading state; a loopback WAV played with the expected duration and no media error. No meeting data was changed.

# Technical debt

None in the export path. This is an experimental inspection tool, not an automatic identity classifier. Reference coverage and the production clustering method remain evaluation limits rather than hidden fallback behavior.
