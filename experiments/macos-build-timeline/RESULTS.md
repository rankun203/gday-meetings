---
title: macOS build timing results
date: 2026-10-06
status: complete
scope: experiment
---

# Findings

An isolated clean release build and installer staging took **486.03 seconds (8 minutes 6 seconds)**. An unchanged cached build and staging took **10.91 seconds**, about **44.5 times faster**. Both completed successfully on committed revision `759e6fc09f86d9a82b89911a1baa61d568c97afd`.

The longest compiler tasks were FluidAudio's 314-file compilation at **133.80 seconds** and the app's 222-file compilation at **123.43 seconds**. These are individual build-system task durations. Parallel task durations must not be added to calculate wall-clock time.

The counter near completion can wait for a large release compilation task. During this run, the app compiler remained active on several CPU cores while the counter stayed near completion. The counter reports completed tasks rather than remaining elapsed time, and its total increases as new tasks are scheduled.

The cached build performed no source compilation. It still resolved build state, validated the linked platform, copied bundle resources, signed the app, and staged the installer.

# References

- `apps/client-macos-swift/scripts/build-macos.sh`: production compilation, platform validation, bundle assembly, and signing.
- `apps/client-macos-swift/scripts/common.sh`: tool checks and Swift invocation.
- `apps/client-macos-swift/scripts/build-audio-dependencies.sh`: checksum-pinned Ogg, Opus, and opusfile compilation and cache validation.
- `apps/client-macos-swift/scripts/install-macos.sh`: installer staging and Finder interaction after the build.
- [Swift Package Manager task trace writer](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/SwiftBuildSupport/TraceEventsWriter.swift): records task start and completion events using a monotonic clock.

# Experiment Setup

The profiler exported committed Swift client and installer source into an isolated directory without checkout-local build artifacts. It ran the production release script twice without changing source between runs. Installer staging ran after each successful build using commands extracted from the production installer script. Finder automation was excluded. The original app and cache were preserved.

The toolchain was Apple Swift 6.4, targeting arm64 with macOS SDK 27.0 and an app minimum of macOS 26.0. Native compilation used 10 jobs. Swift's task trace option was added only to the disposable source copy. The report records the commit and toolchain.

A monotonic clock timestamps shell trace boundaries and compiler output. A shell command interval ends at the next observed selected command; it includes shell overhead and any intervening unselected nested calls. Swift task durations come from build-system start and completion events. Task start times use a separate trace origin after package resolution. All bars use the same seconds-per-width scale.

“Clean” means an empty checkout-local build cache. “Cached” means the same source and build directory immediately after the clean build. This comparison does not measure an incremental rebuild after changing source. No ablation was needed for this unchanged-cache comparison.

# Results and limitations

| Measurement | Clean | Cached |
| --- | ---: | ---: |
| Release build and installer staging | 486.03 s | 10.91 s |
| Installer staging, included above | 0.29 s | 0.31 s |
| Recorded Swift build-system tasks | 659 | 7 |
| Native audio build/check command interval | 29.33 s | Under 0.1 s |
| FluidAudio source compilation task | 133.80 s | Reused |
| App source compilation task | 123.43 s | Reused |
| Exit code | 0 | 0 |

The interactive report, task traces, metadata, and logs are under `runs/committed/`. Open `runs/committed/timeline.html` to compare the totals, inspect named stages, and filter or sort individual tasks. The overview names downloads, version selection, and source checkouts for all nine Swift packages, labels the local Ogg, Opus, and opusfile archives with their versions, and groups compilation by target and shows disjoint periods of task activity; overlapping stages cannot be summed. Raw assignments and shell commands are retained in logs rather than shown as stages. These generated artifacts are ignored by Git.

An earlier working-source snapshot failed after 275.04 seconds because concurrent semantic-search work had compile errors. It recorded 652 completed task events, but no cached comparison was attempted for that failed snapshot. Its report and diagnostics remain under `runs/traced/`; its disposable source copy was removed. The successful comparison uses committed source rather than modifying the concurrent work.

The measurement does not reset operating-system caches or network infrastructure. One pair of builds cannot establish a stable average; concurrent CPU and filesystem activity can affect durations. Source extraction and report generation are outside the timed interval. Native audio libraries have a combined command interval; their individual compiler jobs are not in Swift's task trace. Compiler output timestamps measure message arrival, not job duration.

The clean build emitted linker warnings about missing Command Line Tools framework and library search directories. The cached build emitted no linker warnings. Signing and strict signature verification succeeded. No deprecation warnings appeared in the release logs. Browser preview validation was blocked by the browser's local-file URL policy; report generation, HTML structure, JavaScript syntax, and filtering and numeric sorting were checked without a browser preview.
