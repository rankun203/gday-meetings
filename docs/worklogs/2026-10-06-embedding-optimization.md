---
title: Core ML embedding optimization experiment
date: 2026-10-06
status: validated-with-measurement-limits
scope: search-model-performance
---

# Problem

Published FP32 embedding models passed accuracy checks, but interactive search needs measured load and inference latency. Automatic FP16 previously failed on attention-mask arithmetic. Weight compression alone does not establish a latency improvement.

# Implemented solution

Added reproducible conversion, native benchmark, compute-plan inspection and paired retrieval tools in `experiments/embedding-optimization/`. Evaluated 16 model/shape variants, conservative and bounded-mask FP16, and 4/6/8-bit palettes. Compared 102 queries and 1,677 passages with FP32, including short-query/long-document pairings. Generated artifacts and private evaluation receipts stay ignored; aggregate measurements and the self-contained results report are repository artifacts. Published generic mixed-FP16 variants in the existing Hugging Face repositories at `mixed-fp16-v1`, preserving FP32 `v1`. Verified all 17 uploaded files per repository. The app registry adopts the new assets, the embedding actor warms the 128-token default function and lazily loads the 512-token function, and model-space versioning triggers an index rebuild.

# Reasoning

Separate compute precision, weight storage, input length, and compute-device policy. Conservative selective-FP16/128 queries preserve all baseline first results and top-five sets against FP32/512 documents. Warm latency is 6.30 ms for 97M and 9.50 ms for 311M, versus 8.44/25.00 ms for FP32/512 on this M1 Max. Bounded-mask/128 is faster (4.09/8.89 ms), but the 97M query model loses one top-five evidence hit when paired with rebuilt selective-FP16 documents. Recommend conservative selective precision first, retain 512-token documents and long-query fallback, and use Core ML multifunction packaging to share weights. Combined functions reproduce the separate functions exactly on all evaluated vectors; packages are about 196/625 MB. Resident-memory profiling remains a measurement limit. Palettization saves disk space but provides no consistent speed advantage and changes retrieval.

# Technical debt

No production debt introduced. The bounded-mask experiment overrides a private method in the pinned Transformers ModernBERT implementation. This coupling is accepted only for reproducible experimentation; changing the dependency requires rechecking the mask implementation and rerunning numerical/retrieval tests. Promote it to a maintained conversion wrapper with boundary tests before any production adoption. The deployed multifunction package deduplicates shared weights; separate per-shape artifacts remain experiment inputs only. Resident-memory measurement remains a documented evaluation limit.

# Notes

All evaluated vectors were finite, and additional seven-probe checks cover the original long synthetic input. Three-process latency comparisons were repeated after laptop sleep, with identical short probes and nominal thermal state. Accuracy runs overlap other work, so their incidental timings are excluded. Native benchmark compiled with optimization; Python scripts passed syntax checks; report tables were generated from aggregate receipts. The layout agent separately validates app UI and its release build.

A first compilation attempt used Command Line Tools, which lacks `coremlcompiler`; a per-command full-Xcode `DEVELOPER_DIR` resolved it without changing global settings. An FP32-source palette trial needed scikit-learn and was stopped; completed palette trials consistently use selective-FP16 input and weighted `kmeans1d`. Fixed-trace/dtype/optional-argument conversion warnings and the pinned tokenizer's regex heuristic warning remain documented in RESULTS.md. Core ML emitted cache-recovery diagnostics and a CPU+ANE compilation failure/fallback during device-policy tests. These runs are not described as successful ANE execution or warning-free validation.

The final isolated release build passed (95.47 seconds), including packed-vector storage and the search focus follow-up, and the staged app signature verified. Targeted tests use the repository’s explicit Swift Testing plugin workaround after a direct SwiftPM invocation failed to discover the plugin. Authorized real-library indexing completed for all 366 meetings without failures. Sixteen queries exposed a 4.36-second JSON-index bottleneck; the packed-index follow-up reduced median search to 416 ms with identical ordered top-five results. See the packed-search-index worklog for storage details. Private inputs/results stay ignored. Computer use resumed after the user unlocked the Mac. The updated Preview downloaded and prepared the published 97M variant, returned semantic results, wrapped excerpts correctly, played a matching timestamp, opened its transcript row, and restored the search selection with Back. Nine targeted search/configuration tests passed using the release test bundle.
