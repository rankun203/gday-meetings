---
title: Native search dependencies
date: 2026-10-07
status: active
scope: macos-search-dependencies
---

# Native search dependencies

The app statically links [USearch 2.26.4](https://github.com/unum-cloud/USearch/tree/v2.26.4)
and [NumKong 7.8.5](https://github.com/ashvardanian/NumKong/tree/v7.8.5).
Unmodified source archives are pinned by SHA-256 in `scripts/build-search-dependencies.sh`.
The normal Make entry points compile them with Command Line Tools and link
one static archive. No downloaded binary or deprecated build backend is used.
The unmodified upstream Apache 2.0 license files are bundled with release builds.

USearch supplies HNSW with INT8 storage and native cosine kernels. The app
uses its C API through a system module to control construction/search
breadth, filtered retrieval, and deterministic native-handle destruction.
The source build enables native instruction dispatch; unsupported hardware retains
upstream fallbacks. SQLite stores packed original FP32 vectors for reranking.

The upstream NumKong SwiftPM manifest declares a header-only C target. Swift
Build in the tested Swift 6.4 toolchain attempts to link a nonexistent
`CNumKong.o`. Building the unchanged C/C++ sources follows the established
native-audio build pattern and avoids mutating package checkouts. Before direct
SwiftPM use, run `bash scripts/build-search-dependencies.sh` as well as the
audio dependency script. Both generated archives stay in `.build`.

Version 7.8.5 includes the upstream Apple Silicon dot-product detection fix.
On M1 Max, `FEAT_DotProd` is available while `FEAT_I8MM` is not; the former
selects the supported `neonsdot` kernel. Runtime feature detection remains enabled.
