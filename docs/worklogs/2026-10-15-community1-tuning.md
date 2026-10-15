---
title: Community-1 configuration ablation harness
date: 2026-10-15
status: measured
scope: experiment
---

## Problem

Measure whether a denser segmentation hop improves coverage and agreement enough to justify its resource cost. Existing remote final-word labels lack raw acoustic turns and cannot establish diarization ground truth.

## Implemented solution

Extended the experiment-only Community1Benchmark with baseline, dense-hop, and overlap-output profiles plus configuration-only inspection. Added `experiments/community1-tuning/` with an offline cached build, verified model-link staging, serial resource measurement, normalized acoustic exports, and synthetic checks. No production defaults or library data changed.

## Reasoning

Change one field at a time. Baseline and dense-hop runs use identical float PCM decoded once from the original copied Opus and the immutable timing source. The native loader rejected Opus before inference; decoding format, hashes, sample counts, and preparation cost are recorded separately. Overlap retention is a separate deferred ablation. Fresh processes and recorded complete configurations make costs and differences inspectable.

## Technical debt

The isolated build rewrites package dependency locations to existing local caches while keeping computational source pinned. This bridge avoids downloads and app build interference; refresh the staged package after source changes. The catalog reader intentionally accepts only the current 21-asset structure and fails if it changes; update it alongside a future model catalog revision. Linker warnings reference missing Command Line Tools search directories, although linking and synthetic executable checks pass. Resolve the toolchain paths before treating builds as warning-free.

## Validation

Release executable built successfully. Three synthetic tests passed: exact single-field profile changes, invalid-profile rejection, overlapping-turn preservation, scoped stable speaker IDs, timestamp bounds, identical-support agreement, and omitted/duplicate text anchors. All 21 cached model assets passed catalog size/digest verification. Authorized serial runs completed: baseline/dense inference took 36.02/80.36 seconds; maximum RSS was 0.838/1.157 GB. Assigned spans fell from 13,277 to 13,141 of 14,820. On identical system-audio comparison support, agreement with remote final labels rose from 92.00% to 93.33%; microphone agreement was unchanged. This is a measured tradeoff, not an accuracy win or reason to promote the dense profile. Both projections preserve all 17,981 original UTF-16 units exactly once. Original and decoded audio hashes were verified after inference. No overlap run or additional inference was performed.
