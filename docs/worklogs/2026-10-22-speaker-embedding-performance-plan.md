---
title: Speaker embedding performance plan
date: 2026-10-22
updated: 2026-10-22
status: planned-not-implemented
scope: macos-community1-diarization-performance
---

# Problem

Community-1's offline speaker embedding predictions run sequentially inside a pipeline that overlaps segmentation and embedding extraction. The configuration name `embeddingBatchSize` can suggest that these predictions are already batched; it controls surrounding FBank and PLDA work instead. We need to determine whether batching or bounded concurrency improves complete processing time while preserving speaker labeling and association behavior.

# User Intention

The user asked whether the Swift app parallelizes analysis windows enough to use the available hardware, then requested independent analysis from an Astra agent and Claude Code Opus 5.5. The objective is to identify speed improvements without breaking features or introducing errors. The user subsequently requested this worklog as a plan, explicitly not as implemented work.

# Implemented solution

None. Completed read-only source analysis, inspection of historical benchmark logs, and independent Astra and Claude Code Opus 5.5 reviews. No optimization, experiment harness, model change, or new benchmark has been implemented or run. The running app and user library were left unchanged.

# Evidence and reasoning

The review inspected the working tree based on app commit `f3d0cbe274d85bb8ed95693cdc485672229cdf21`, which contains unrelated uncommitted work, and the clean FluidAudio checkout at `21493f8dac5a97e65742e6ff26f42f164c2fda0f`. These revisions identify the inspected source; they do not identify a newly measured build.

Verified behavior:

- `CommunityDiarization.swift` uses the default offline configuration and processes tracks sequentially under one `communityInference` permit.
- FluidAudio's `OfflineDiarizerManager.prepare` runs two overlapping workers. Each window is segmented before its masks reach embedding extraction.
- Segmentation uses tensor batches of up to 32 windows. FBank uses batch-provider calls of up to 32 independent inputs. Speaker embedding predictions are synchronous and sequential. PLDA, the transformation used for speaker clustering, processes batches of up to 32 embeddings.
- `LocalModelManager` configures FBank for CPU and other models with `.all`. Actual GPU or Neural Engine placement and saturation were not measured.
- Final reconstruction can invoke additional embedding predictions for speech without cluster votes. The app also extracts separate representations for selected voice examples after diarization. Both paths must remain intact.

Historical baseline profiling from the [Community-1 tuning experiment](../../experiments/community1-tuning/RESULTS.md):

| Stage | Microphone track | System-audio track |
| --- | ---: | ---: |
| Segmentation predictions | 12.772 s | 13.249 s |
| Speaker embedding predictions | 7.789 s | 14.594 s |
| FBank | 3.370 s | 3.606 s |
| PLDA | 0.041 s | 0.075 s |

These aggregate values were recovered from that experiment's ignored baseline process logs. The baseline used an M1 Max, the pinned FluidAudio revision above, and one run per track. Segmentation overlaps the embedding worker, so the table cannot be summed into elapsed time. The measurements support investigating embeddings on system audio and suggest a stronger segmentation constraint on microphone audio. Changing concurrency can change contention and stage durations; no speedup or fixed wall-time ceiling is established. The separate [DiariZen comparison](../../experiments/diarizen-comparison/RESULTS.md) logs showed the same source-dependent pattern.

Existing stage instrumentation is useful, but the manager's postprocessing calculation subtracts both overlapping worker durations from total wall time and clamps the result to zero. That derived value cannot reliably isolate reconstruction cost. Future measurements must use explicit wall intervals and distinguish worker execution from time waiting for input.

# Proposed plan

All steps remain pending. Evaluate each candidate independently before combining changes.

1. **Establish a fresh baseline.** Freeze input bytes, decoder, model hashes, dependency revision, release executable, configuration, and compute policy. Measure queue wait, loading, audio preparation, pipeline wall time, individual model calls, clustering, reconstruction, and optional voice-example extraction. Record cold and resident-model runs separately. Inspect actual device utilization with Core ML instruments or compute-plan tooling.
2. **Compare small embedding batches.** Test the Core ML batch-provider API with 2, 4, and 8 independent inputs of the existing shape. This differs from changing the model's tensor batch dimension and can be evaluated without re-exporting it. Preserve original mask selection, result ordering, and PLDA flush boundaries. Batch calls may still execute mostly sequentially; benefit requires measurement.
3. **Compare bounded async prediction.** Independently test 2–4 in-flight embedding predictions using the supported async API. Keep mask preparation serial, retain immutable inputs until completion, and restore original chunk/speaker order before PLDA and clustering. Keep the outer Community model-access permit initially. Drain outstanding work on cancellation or failure before releasing inputs or shared-model access.
4. **Avoid unused FBank work.** Prepare masks with the exact existing overlap, occupancy, fallback, interpolation, and energy rules before calculating audio features. Skip FBank only when every mask would already be rejected. Preserve every segmentation chunk and its timing for reconstruction. Share the eligibility implementation so a precheck cannot drift from extraction. Preserve batch-boundary semantics or restrict this optimization to the existing disabled embedding-skip strategy.
5. **Reassess the pipeline.** Measure whether segmentation becomes the limiting stage and whether extra embedding work delays other model calls. Repeated PLDA warmups are a minor cleanup candidate; all PLDA work in these baselines was below 0.1 second per track. Mask arithmetic was also negligible.

Any dependency implementation must live in the maintained FluidAudio source or fork and a pinned revision. Editing only SwiftPM's generated `.build/checkouts` directory is not a durable solution. New experiments should follow the repository's `experiments/<name>/` workflow with a reproducible README and coherent RESULTS document; none has been created for this plan.

# Correctness and acceptance criteria

- Preserve mask eligibility, source offsets, chunk/speaker associations, embedding count and order, and finite vector outputs. Keep buffers alive and unchanged until their predictions finish. Existing pooled mask-preparation buffers must not be mutated concurrently.
- Compare embeddings and PLDA vectors against repeated baseline runs. Establish baseline numerical variability before selecting tolerances. Require unchanged speaker partitions after label permutation, turn boundaries, overlap behavior, transcript attribution, and selected voice examples. Vector similarity alone is insufficient because clustering can amplify small differences.
- Include silence, sparse speech, overlapping speakers, short and trailing windows, changing chunk-local speaker indices, threshold-adjacent examples, long recordings, and multiple tracks. Preserve short-speech recovery during reconstruction.
- Test cancellation and failure at each affected stage, retry, model acquisition/release, source revision changes, stale-result rejection, and recording starting during offline work. A failed or cancelled preparation must not publish partial results or retain its permit.
- Run repeated paired release measurements with varied candidate order and no competing benchmarks. Accept a change only when complete elapsed-time gains exceed observed variation without material memory, microphone-track, cancellation, or live-workload regressions. Set concrete thresholds from the baseline before evaluating candidates.
- Use synthetic fixtures for committed tests. For library-dependent trials, follow the repository's isolated-copy procedure for the latest 20 completed meetings, preserving active work, disabling remote providers and automatic processing, and keeping private inputs and artifacts ignored.
- Before any implementation handoff, inspect the complete diff, run relevant regression checks, validate an isolated macOS release build, and obtain independent follow-up review. UI changes are outside this plan.

# Independent review decisions

Astra and Claude Code Opus 5.5 both completed read-only reviews. Both supported bounded embedding execution and exact eligibility checks before FBank, with numerical and final-output parity checks. Opus preferred batch-provider calls first because they fit the existing serial preparation flow; Astra supported comparing batching and async concurrency. The plan accepts both as separate experiments.

Astra identified repeated PLDA warmups and misleading derived postprocessing timing. After examining the saved stage logs, it demoted PLDA cleanup and prioritized embeddings. This assessment was accepted.

The primary review rejected Opus's assumption that Neural Engine placement was established and treated its estimated wall-time ceiling as a hypothesis. Its proposed macOS 14 gate does not apply to this app's macOS 26 minimum. Neither review establishes a measured optimization gain or guarantees output equivalence.

Rejected shortcuts include enabling mask-similarity embedding reuse across changed audio, raising global Community job concurrency, dropping queued segmentation chunks, and changing segmentation hop, thresholds, precision, or clustering scope as if they preserved behavior. Mask shape and a chunk-local speaker index do not establish identical voice content. Any future queue bound must apply backpressure without dropping evidence.

# Technical debt

None introduced by this planning task. Existing repeated PLDA warmups and the overlapping-duration subtraction remain unchanged pending measurement work; their consequences and proposed remedies are recorded above. No temporary implementation, compatibility bridge, or schema change has been added.

# Notes

Validation completed: source inspection, historical log analysis, official API guidance review, and independent Astra and Opus 5.5 analysis. No new compilation, automated tests, rendered UI checks, interaction checks, or performance runs were performed for this plan. There is no implementation build or commit to test.

Apple documents concurrent async predictions, batch-provider scheduling, cancellation considerations, and bounded in-flight work in [Improve Core ML integration with async prediction](https://developer.apple.com/videos/play/wwdc2023/10049/). This supports the proposed API experiments, not a promised speedup for Community-1.
