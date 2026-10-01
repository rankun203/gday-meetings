---
title: Standalone Core ML diarization benchmarks
date: 2026-10-01
status: validated-experiment
scope: isolated-diarization-benchmark
---

# Problem

Published model results did not establish whether Nemotron 3 and the Community-1 Core ML pipeline could build and process meeting audio on this Mac, or how their live behavior differs. Model inference was too large a change to add directly to the app before measurement.

# Implemented solution

Two standalone executable products live in `experiments/diarization-benchmark`, developed and release-built in a detached test worktree. The app package remains unchanged. [Results](../../experiments/diarization-benchmark/RESULTS.md) compare processing, resources, startup, and live delay; the [README](../../experiments/diarization-benchmark/README.md) records exact dependency/model pins and commands.

The package pins FluidAudio with its Rust text-processing trait disabled. Explicit model downloads verify hashes at immutable snapshots. Runtime commands load local assets with no download fallback. Nemotron uses its native persistent stream with 20 ms input chunks. Community-1 processes whole recordings or recomputes a causal trailing 30-second window every ten seconds. Window IDs are provisional and do not preserve speaker identity across updates.

The runner validates input hashes and all numeric options, records the complete configuration fingerprint, retains immutable attempts, and verifies output hashes before reuse. Historical results with other binary versions remain explicitly separate. Each child owns a process group and temporary directory; timeout and cancellation stop only that group with bounded escalation and remove decoded PCM. Synthetic subprocess tests cover these failure paths without loading models.

Per-output measurements distinguish scheduled arrival, processing start, output availability, and simulated backlog. Both pipelines timestamp output readiness before segment export. Absolute source coordinates are used consistently for segment and window timestamps. The centered Nemotron frontend produces `1 + (N + 512 - 400) / 160` frames for nonempty input; padded tail intervals are clipped to source duration. Finish is checked for idempotence.

# Reasoning

The shortest published monolithic Core ML input preset tested here is Nemotron `.low` at 1.04 seconds. This permits a native streaming feasibility test. Community-1 tests the supplied compact offline pipeline; its window adapter demonstrates causal replay without pretending to solve cross-window identity tracking. Silence-only throughput would be misleading because Community-1 skips embedding/clustering when there is no speech, so validation includes identical synthetic speech and four authorized real recordings.

Private audio, source paths, reference intervals, per-speaker exports, raw results, and receipts stay outside Git. Existing labels are unverified annotations, not ground truth. Only anonymous aggregate measurements are published.

# Validation

Host: Apple M1 Max, 64 GiB RAM, macOS 26.6.2, Swift 6.4, macOS SDK 27.0. Inference ran one process at a time at `nice 10`. The Mac was also recording, and some earlier runs overlapped compilation; these are feasibility observations rather than isolated hardware rankings.

- Both executable products release-built. Shared option/timing helper smoke checks, 54 invalid-option executable checks, 22 dispatch checks, and strict Swift formatting passed. Unsupported flags are rejected before model loading instead of accidentally starting silence benchmarks.
- Ten portable runner tests passed in 9.61 seconds. They cover input/configuration changes, tampering, historical preservation, execution gates, timeout, SIGINT/SIGTERM/SIGHUP, descendant termination, temporary-file cleanup, and unrelated-process survival.
- All eight full-file runs completed: four identical prepared recordings for each model, totaling 177.75 minutes of input per model. Runtime checks reported no linked native Rust normalizer.
- Community-1 completed accelerated window replay for all four full recordings. Nemotron saved-file processing already uses the same native chronological chunk path, so an identical accelerated replay was not repeated as a separate test.
- Four final one-minute paced runs completed on matching excerpts from two samples. Nemotron's first probability output arrived in 1.205–1.228 seconds; the Community-1 adapter's first window arrived in 10.183–10.197 seconds. Neither is a stable-speaker-label latency claim. Maximum simulated backlog stayed below 0.168 and 0.365 seconds respectively in these short runs.
- The preliminary Nemotron completion timestamp included export work. The final correction captured readiness immediately after inference and final flush, matching Community-1. Both affected excerpts were repeated; final hashes and measurements are in Results. Earlier full-file measurements retain their original hashes and private binaries.
- The initial five-second framing assertion expected 500 frames and observed 501. Upstream frontend inspection established the centered-frame formula; the corrected framing checks passed. This was a harness expectation error, not an upstream model edit.

The final Nemotron timestamp build passed in 90.73 seconds. Most of the delay was an idle SDK stat-cache helper waiting in its event loop. It recovered before a targeted termination attempt reached it. Refreshing that generated SDK cache then produced a successful incremental build in 1.25 seconds. An earlier incremental Swift Build stall required refreshing generated experiment output; no supported replacement API was bypassed and the deprecated native build backend was not selected.

Builds retain missing Command Line Tools developer library/framework search-path warnings. No app API deprecation warning was introduced. SwiftPM downloaded an 87.3 MB optional Rust artifact despite disabled traits; downloading is distinct from linking. The generated speech fixture, model-free helpers, and short paced excerpts do not establish diarization accuracy, Intel support, minimum macOS behavior, battery cost, or sustained thermal performance.

# Technical debt

FluidAudio exposes no isolated diarization product, so its full Swift library and C/C++ helpers compile. Optional artifact fetching and the observed SDK/build-cache delays need supported-toolchain matrix verification before adopting the dependency in the app. Keep the exact revision while that work is pending.

Community-1 replay has no persistent speaker matching or revision handling. Its provisional IDs cannot be presented as stable live identities; a production adapter needs explicit reconciliation and manually reviewed evaluation data. Nemotron's eight-slot limit also needs product behavior for meetings with more speakers.

Some small measurement utilities remain duplicated, while option parsing and live timing are shared. Timing arrays are bounded by explicit run limits but should become bounded histograms for longer soak tests. Process RSS and physical footprint omit potentially separate Core ML service allocations; broader memory profiling is needed before setting a production budget. Runner cleanup cannot cover forcibly killing the runner itself or loss of power; its uniquely named temporary directories can remain in those cases.

# Saved-annotation comparison

Added an exact interval scorer with one-to-one permutation matching, overlap handling, boundary-collar sensitivity, and explicit unknown gaps. Private reports retain input hashes and disagreement intervals. Seventeen synthetic tests passed, including 400 independent event-grid/exhaustive-matching cases and CLI input/output protection. They cover permutation, split speakers, duplicate intervals, missing/extra speech, unknown gaps, collars, invalid timestamps, and assignment checked against brute force.

A read-only Rust provenance audit found matching raw/enriched extraction artifacts but no retained per-meeting provider receipts. Current RunPod settings do not prove historical routing. The first duration-compatible sample has lower disagreement for Community-1 (18.08%) than Nemotron (23.11%) on annotated speech with overlap and no collar. These are exploratory annotation-relative values, not human-verified accuracy. Two other samples have worker/current-duration mismatches under investigation; the fourth has extensive cross-label overlap. Known-good reference selection was requested from the user. No source meeting files were modified or submitted to a provider.

This retains reference-quality debt: manually verify the selected speech boundaries, identity labels, and timeline before reporting model accuracy. Private source provenance and decoding diagnostics must accompany future comparisons rather than treating current configuration or identity confidence as historical evidence.

The final runner regression repeat passed all ten tests in 9.31 seconds with process inspection enabled. A sandboxed attempt could not launch `ps` for four cleanup checks; the permitted repeat verified those cases. Reviewed reference scoring reproduced the recorded sample values exactly.

Current FFmpeg native Opus and libopus decoding agreed on sample counts for both mismatched references; packet timestamps were contiguous. The historical duration discrepancy remains unresolved. Their reference scores are withheld rather than correcting timestamps without source evidence.

# Independent evaluation

Added a root `tmp/` ignore rule for private meeting analysis at the user's request. Output checks allow that directory only when Git confirms it is ignored and untracked. Meeting-specific artifacts remain private; generic tools and aggregate measurements are tracked.

Extended interval scoring with explicit reviewed regions so verified silence counts toward false alarms. Added an independent-review scorer that rejects unreviewed or disagreement-selected data. The evaluation protocol distinguishes server agreement from independently reviewed accuracy, named-person recognition from voice grouping, and final labels from labels available live. Synthetic tests include a local model correctly improving on a mistaken server baseline.

Independent listening remains required before claiming improvement over the server. This is evaluation-data debt: prepare blinded clips, annotate speech and silence, adjudicate uncertainty, and score all systems against the same frozen reference. Source-track timing discrepancies must remain explicit rather than fitting time corrections to maximize agreement.

Validation: 45 synthetic tests pass across reference scoring, reviewed-audio scoring and privacy paths, blinded clip generation/export, and runner lifecycle behavior. The interval sweep was checked against 1,200 independently integrated cases. Current full-file Community-1 exports include a positive window end with `provisional: false`; parsers now accept that offline schema while rejecting provisional rolling-window exports. Tests cover this distinction. No Swift app code or model settings changed in this follow-up.

All eight new single-track runs completed, covering 173.59 minutes per model. Community-1 took 52.66 seconds total; Nemotron took 790.83 seconds. On the two timing-compatible references, pooled annotated-speech disagreement was 17.48% and 28.24% respectively with no collar. Two remaining reference comparisons are withheld for timeline discrepancies. Forty independent and twelve diagnostic 20-second clips were generated with blank annotation templates, input/clip hashes, and separate private keys. Their review, source mappings, and detailed results remain under ignored `tmp/`; Git lists no tracked files there. No independent accuracy claim is made until listening and adjudication are complete.
