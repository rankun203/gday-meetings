---
title: Swift tokenizer dependency notices
date: 2026-10-06
status: active
scope: macos-app-binary-distribution
---

# Swift tokenizer dependency notices

These unmodified license and notice files accompany the Swift Tokenizers dependency graph pinned in `Package.resolved`. They apply to the app binary and tokenizer resource bundle, separately from the downloaded CLSP model distribution. Keep the original files when redistributing the app.

| Component | Revision | License |
| --- | --- | --- |
| eventsource | `86b5096ac59ab46e66bd1f6377c604bc1dab0bc2` | MIT |
| swift-asn1 | `3b6410f7dee09eb33cdd26260c5fd47fda19b0e2` | Apache 2.0 |
| swift-collections | `98ef3c98609a1e31b7e157b5b619579001a789d6` | Apache 2.0 with Swift exception |
| swift-crypto | `da9d28d69ebe3894b18376c8f2395c2f37b8448f` | Apache 2.0 |
| swift-huggingface | `f0a0cb43cb1b402d2bbf6fb10d8981328c449c48` | Apache 2.0 |
| swift-jinja | `4588064a20f3fc093c95f2f7d3359999bf30cae5` | Apache 2.0 |
| swift-transformers | `c21fdcde390313a6d98d8e33a346f2c3486c3ab0` | Apache 2.0 |
| yyjson | `8b4a38dc994a110abaec8a400615567bd996105f` | MIT |

The `Tokenizers` target depends on `Hub` and `Jinja`. `Hub` also depends on HuggingFace, OrderedCollections, Crypto, and yyjson; HuggingFace depends on EventSource and Crypto. The app bundles `swift-transformers_Hub.bundle` because tokenizer fallback configuration reads `Bundle.module`.

Swift Crypto uses Apple's CryptoKit on this macOS build. Its BoringSSL and XKCP targets are conditional dependencies for other platforms, and the app does not select CryptoExtras. SwiftASN1 is resolved through CryptoExtras but is not a dependency of the selected macOS Crypto target; its upstream notices are preserved here as well. Xet and dependency test targets are not selected. Recheck this scope when package versions, products, platforms, or build traits change.

The complete upstream Swift Crypto and SwiftASN1 NOTICE files are retained, including their descriptions of upstream test vectors and build scripts. Preserving these notices does not mean the app ships those test datasets or scripts. No third-party source was modified for this app integration.
