---
title: Standard meeting language choices
date: 2026-09-26
status: implemented
scope: swift-app-language-selection
---

## Problem

The recording-language picker depended on the selected batch provider, while This Mac used a separate regional list. A saved choice could resolve to an unexpected live model or become unavailable merely because no provider was configured.

## Implemented solution

Added an offline app-owned catalog with thirteen choices: the existing eleven plus Italian and Cantonese. English appears once. Recording, meeting details, and defaults share the catalog. Existing stored codes are preserved; known aliases display as standard choices. Batch adapters resolve explicit provider codes before upload and save the result separately in each transcription attempt. Retries retain the exact request code, including legacy attempts. Chinese Simplified and Traditional never fall back to bare Chinese or each other. The companion This Mac change maps standard choices to explicit runtime-checked locales.

## Reasoning

A stable menu keeps recording independent of provider configuration. Adapter mappings make differences visible and reject unsupported requests before sending audio. A separate optional attempt field preserves backward compatibility and idempotency without changing meeting-language storage.

## Technical debt

The fixed preferred regional mappings intentionally consolidate old regional aliases for new jobs; stored values remain recoverable. Supporting selectable dialects later requires separate spoken-language/region and output-script settings. RunPod's built-in list can still differ from a deployed worker; retain its existing drift policy and regenerate it when worker support changes.

## Validation

All 250 tests in 52 suites passed, including mapping, legacy decoding, separate request snapshots, unsupported-before-upload, provider caching, and Apple model ordering. Formatting, lint, and Preview packaging passed. Preview showed all thirteen choices without a configured provider and preserved Chinese Traditional selection. Light and dark This Mac settings showed one English choice with its US locale, both Chinese scripts, Italian, Cantonese, and unavailable unsupported languages. No audio upload, model download, or hardware capture occurred. Existing Command Line Tools linker search-path warnings remain; no new API deprecation warning was reported.
