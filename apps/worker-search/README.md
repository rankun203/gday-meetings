---
title: Local audio search worker
date: 2026-10-05
status: prototype
scope: audio-retrieval-benchmark
---

# Local audio search worker

This optional Python subprocess evaluates CLSP speech-style embeddings. It is not yet bundled with the Mac app or evidence of retrieval quality on meetings. The main app remains usable without Python or model downloads.

From this directory, prepare weights explicitly with `uv run gday-search prepare`, then start `uv run gday-search serve`. Preparation downloads the pinned CLSP revision and its RoBERTa tokenizer/configuration. Serving uses the prepared cache offline and loads the model only for an embedding request. Use `HF_HOME` to select the model cache. CPU is the baseline; MPS is experimental until measured.

The Mac app's native Local Voice Search integration uses managed Core ML models in Service Providers. It no longer launches this Python worker or asks for an executable path. Building the voice index remains a separate action. This environment is retained for reference inference and retrieval evaluation; see [Core ML conversion](coreml/README.md) for the separate, pinned conversion environment and current validation limits.

The subprocess accepts one JSON object per line and emits one final response per request. `health` reports whether the model is loaded without loading it. `embed_text` takes a `texts` array. `embed_audio` takes a local audio `path`, optional `start`, and `duration` in seconds (up to 30). Files are decoded locally, mixed to mono, and resampled to 16 kHz. Example:

```json
{"id":"fixture-query","operation":"embed_text","texts":["A quiet, low-pitched voice speaking slowly."]}
```

Output includes model/revision, preprocessing version, dimension, normalization, vectors, and measured inference time. stdout contains protocol responses; diagnostics use stderr. The worker does not open SQLite, change People assignments, or upload audio. The app's shared database layer owns derived index tables; reproducible embedding artifacts stay inside each meeting's provider folder. Rebuilding the database from saved embeddings does not load this worker.

The pinned upstream model includes custom Python code. Reviewed imports and model/tokenizer loading paths are recorded in the research artifacts. Dependency deprecation warnings must remain visible. This prototype does not claim a complete security audit, demographic accuracy, semantic spoken-content retrieval, or native Mac performance.

See [model research](../../docs/design/2026-10-05-audio-search-research.md) for candidates, limits, licensing sources, and the evaluation plan.
