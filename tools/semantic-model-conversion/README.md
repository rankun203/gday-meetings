---
title: Semantic model conversion
date: 2026-10-07
status: active
scope: public-model-conversion
---

# Semantic model conversion

These developer tools convert pinned public Granite encoders to the Core ML assets used by Local Search. They are excluded from the app bundle. Run the scripts with the locked project environment in this directory; model downloads and generated packages belong in ignored folders.

```sh
uv run scripts/convert_granite_coreml.py --help
uv run scripts/package_granite_coreml.py --help
```

Use `scripts/validate_granite_coreml.swift` for the existing synthetic shape and numerical probes. The scripts retain their measured validation limits; conversion does not establish retrieval quality or UI responsiveness.
