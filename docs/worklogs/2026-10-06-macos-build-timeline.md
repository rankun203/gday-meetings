---
title: macOS build timeline
date: 2026-10-06
status: complete
scope: macos-build
---

# Problem

The production build counter does not show which steps consume elapsed time or how much an unchanged cached build saves.

# Implemented solution

Added an isolated profiler under `experiments/macos-build-timeline/`. It measures clean and cached production release builds and installer staging, then generates a shared-scale HTML timeline, raw Swift task traces, structured timings, metadata, and logs. The overview uses named stages instead of raw commands or assignments. It names all nine Swift package downloads, version selections, and checkouts from paired log messages. Ogg 1.3.6, Opus 1.6.1, and opusfile 0.12 are identified as checked-in archives with no download. Unobserved manifest/startup intervals remain separate. It separates preparation, compilation by target, linking, packaging, signing, and staging. Task groups show disjoint active intervals and count overlapping tasks once within each group. Task positions are aligned approximately to the observed build-start message. Tasks can be filtered by name and sorted by start time or duration. Reports can be regenerated without rebuilding.

# Reasoning

Use production scripts and extract installer staging commands to avoid maintaining a second packaging implementation. Add Swift 6.4 task tracing only to the disposable copy. Distinguish shell command intervals, exact build-system task durations, and compiler output observations. Use committed source for a stable comparison while other work edits the working tree.

# Technical debt

None. Production build behavior is unchanged. Profiling requires a toolchain with the experimental task trace option and checks support before building. Injection points are checked so changed production scripts fail explicitly instead of producing a different measurement silently.

# Notes

- Committed revision `759e6fc`: clean release build and staging 486.03 seconds; unchanged cached build and staging 10.91 seconds. Both builds and strict signature verification passed. The app was not launched, and the original app and cache were preserved.
- FluidAudio compilation took 133.80 seconds; app compilation took 123.43 seconds. The cached trace contained seven tasks and no source compilation.
- An initial working-source snapshot failed on concurrent semantic-search compile errors. Its diagnostics remain in ignored outputs. Abandoned source copies were removed.
- Python lint, formatting, report generation, HTML structure, JavaScript syntax, filtering, and numeric sorting were checked. Browser preview validation was blocked by the local-file URL policy; no visual screenshot comparison was possible.
- Existing Command Line Tools framework and library search-path linker warnings remain. No deprecation warnings appeared in the release logs. Finder interaction was excluded. No commit or push was made, so CI was not run.
