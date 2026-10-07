---
title: Speaker pipeline scale results
date: 2026-10-08
status: measured
scope: synthetic-performance-validation
---

# Speaker pipeline scale results

## Findings

Retaining all meeting embeddings exposed avoidable repeated scans. Equivalent algorithms reduced measured consolidation time for 5,760 samples from 0.622 seconds to 0.052 seconds and for 512 mergeable local units from 4.110 seconds to 0.112 seconds. Reviewed-example conflict detection for 8,000 nonoverlapping examples fell from 18.667 seconds to 0.007 seconds. No evidence cap or sample removal was introduced.

These are algorithm timings from one local run per workload, not app responsiveness or speaker accuracy measurements. The separate full-store check measured 3.010 seconds on the main actor for 8,000 confirmed embeddings. This remains a UI responsiveness issue, so moving hydration and selection off the main actor is the next required fix.

The full People profile-path benchmark is implemented and pending execution. It measures `VoiceLibraryStore.matchingPeople` with 8,000 persisted confirmed representations across eight people, including disk reads, selection, and release. Its result must be reported separately from the pure conflict sweep; see the [run instructions and JSON schema](README.md#full-people-profile-path).

## References

The production [consolidation implementation](../../apps/client-macos-swift/Sources/GdayMeetings/Core/SpeakerConsolidation.swift) uses complete-link similarity: two groups can merge only when their least-similar members meet the threshold and constraints permit merging. Caching this minimum allows a merged group's similarity to be updated as the minimum of its two predecessor values. This preserves the decision rule and avoids reconstructing all cross-products on each scan.

The [review conflict implementation](../../apps/client-macos-swift/Sources/GdayMeetings/Core/VoiceLibraryStore.swift) uses sorted interval sweeps. Only the largest endpoints belonging to two different person IDs are needed to answer whether any other person's interval overlaps. A reverse sweep marks conflicts with later intervals. Nil person decisions form their own group. No external algorithm library is used.

The [consolidation equivalence checks](../speaker-consolidation/README.md) compare exact output against the previous implementation across 192 synthetic cases, including capacity boundaries, overlapping samples, merge ties, and overlap constraints. Those checks passed separately from these scale timings. Focused review-conflict tests compare the sweep with the original rule on varied recording keys, excluded reviews, nil decisions, nested intervals, and touching boundaries.

## Experiment setup

Runs used optimized Swift 6.4 on arm64 macOS. Timings are elapsed seconds around the algorithm call, excluding input construction and compilation. Other work could run on the machine; results are single observations without confidence intervals. The runner records exact source hashes, executable hashes, compiler version, and output hash in private receipts.

The sample workload places a three-second sample every five seconds on one local label. The unit workload uses one sample per sequential window with no overlap and identical embeddings, so all units merge. Both produce one cluster. The conflict workload uses sequential three-second examples every four seconds, distributed across three people and a nil-person bucket in one recording. There are no conflicts, forcing the original pair scan to inspect every candidate. The new and old conflict sets must match at every size.

Private receipts are under `tmp/speaker-pipeline-scale-consolidation-baseline-20261008`, `tmp/speaker-pipeline-scale-consolidation-optimized-20261008`, and `tmp/speaker-pipeline-scale-conflicts-20261008`. Baseline consolidation source SHA-256: `a4389c57f3bc00888f7d8d3e94a2f5ed08223525ad9878af6982bff49fab82b7`. Optimized source SHA-256: `bf9bccf675b62764f4fd9c2592a1a1c7dbef67c02b4a4da8ef15d7fa58c23e5e`.

## Results

| Workload | Count | Previous seconds | Optimized seconds |
| --- | ---: | ---: | ---: |
| Samples on one label | 720 | 0.022264 | 0.008120 |
| Samples on one label | 1,440 | 0.084509 | 0.012770 |
| Samples on one label | 2,880 | 0.190888 | 0.027151 |
| Samples on one label | 5,760 | 0.622162 | 0.052253 |
| Mergeable local units | 64 | 0.009954 | 0.002151 |
| Mergeable local units | 128 | 0.067378 | 0.006107 |
| Mergeable local units | 256 | 0.514771 | 0.024761 |
| Mergeable local units | 512 | 4.109768 | 0.111762 |
| Reviewed examples | 2,000 | 1.637880 | 0.002734 |
| Reviewed examples | 4,000 | 4.732660 | 0.003446 |
| Reviewed examples | 8,000 | 18.667048 | 0.006563 |

Consolidation now measures sample coverage using merged interval unions and a moving cursor. Sample-derived boundaries that previously coalesced into the same output interval no longer trigger repeated scans. Complete-link group similarities reuse a cached minimum while preserving group order and tie behavior.

People matching now computes conflict IDs once, then reads examples through the existing person index in metadata order. The conflict sweep sorts each recording's spans, requiring O(N log N) time and O(N) auxiliary storage for N reviews. It preserves recording revision, audio-file, review, exclusion, range, and person-decision rules.

## Full People profile path

The release-mode opt-in test passed with 8,000 confirmed 256-dimensional vectors across eight people. The complete `matchingPeople` call took **3.009986 seconds**, including representation reads, profile selection, and release. Each person retained exactly twelve matching samples. Bulk persistence and metadata construction were outside the timer; application representations were released before the call, while filesystem cache state was unspecified.

The source-copy comparison and aggregate receipt are recorded in ignored `tmp/speaker-pipeline-scale-full-store-20261008.json`; the release log is `/private/tmp/gday-speaker-profile-scale-release.log`. The integrated app also passed 1,154 tests in 200 suites and a separate release build. The profile measurement demonstrates that fast conflict detection alone does not remove the main-thread stall.

## Limitations and technical debt

Complete-link clustering retains quadratic pair storage and a worst-case cubic scan over active groups. The measured improvement removes repeated member cross-products; it does not make the whole algorithm quadratic. Dense overlap constraints and other vector distributions can have different costs. These workloads do not measure peak memory.

People profile hydration and selection remain proportional to retained confirmed examples and run through the existing store path. The measured three-second main-actor stall is retained at this checkpoint and is being fixed next with owned background readers, cancellation, and revision checks that preserve current reviews. It is not accepted as the final experience. No persistent cache, schema migration, evidence pruning, or temporary compatibility path was added by these changes.

These measurements support the specific scan optimizations. App tests and a release build remain separate integration gates, and model evaluation remains necessary for changes to speaker identity decisions.
