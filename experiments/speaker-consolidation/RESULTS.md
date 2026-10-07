---
title: Retained voice embedding consolidation results
date: 2026-10-08
status: measured
scope: production-speaker-consolidation
---

# Findings

The final production method preserves trusted live identities within each window and uses corrected embeddings to join those units across windows. On two recordings selected before the method's first outcomes, pooled human-reviewed DER improves from **57.33% to 56.02%**, entirely through reduced speaker confusion on D; C is unchanged. Three other recordings serve as calibration or diagnostics. This supports the tested method for new evidence with explicit trusted-window provenance, not a general claim of reliable diarization across meetings.

Grouping individual embeddings independently failed. A concrete short-span padding error was corrected, but corrected sample-level clustering still over-split speakers. The final method addresses that failure by retaining the labeling model's within-window identity decisions.

Capacity rollover completed on the above-capacity recording without gaps or extraction failures. Its targeted-excerpt DER fell from 54.41% to 47.15%, mainly because less speech was missed; confused speaker-time increased slightly. This does not establish an identity accuracy improvement. Below-capacity controls did not roll over.

# References

The [existing local benchmark](../diarization-benchmark/RESULTS.md) provides frozen worker outputs, audio hashes, and human-reviewed excerpts. Its earlier results compare complete local diarization pipelines, not the new retained-embedding method.

[Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) combines local speaker segmentation, WeSpeaker embeddings, and global clustering. [FluidAudio's offline implementation](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md) supplies PLDA/VBx clustering for its extraction recipe. This experiment instead evaluates the app's complete-link cosine clustering on the clean short spans generated during live processing; the full offline pipeline's thresholds do not establish calibration for that sampling policy.

[Nemotron 3](https://huggingface.co/nvidia/Nemotron-3-Diarization) uses eight arrival-ordered output channels and a streaming speaker cache. Capacity rollover starts a new local namespace; embeddings provide evidence for associations across those namespaces.

## Model alternatives

Official model cards and implementation documentation were checked on 2026-10-08. These are available implementations, not a ranking from this experiment; no replacement model was downloaded or benchmarked here.

| Option | Role and evidence | Apple Silicon deployment and license | Decision for this change |
| --- | --- | --- | --- |
| Full [Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) pipeline | Offline recording-level labeling, speaker counting, and exclusive diarization for transcript alignment; recomputes the audio timeline rather than only regrouping retained samples. | Official Python pipeline; the app already has FluidAudio's native counterpart. Model is CC-BY-4.0; official downloads require accepting access conditions. | Keep as a separate full recording analysis option. It can examine speech absent from retained samples, at the cost of another audio pass. |
| [SpeechBrain ECAPA-TDNN](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb) | Convolutional/residual speaker encoder with attentive pooling; trained on VoxCeleb 1/2, supports cosine verification and embeddings. | Official SpeechBrain/PyTorch implementation, Apache-2.0 model card. A native conversion and preprocessing-parity check would need validation here. | Credible embedding comparator. Its reported verification error is not evidence of lower meeting diarization error. |
| [NVIDIA TitaNet-Large](https://huggingface.co/nvidia/speakerverification_en_titanet_large) | Approximately 23M-parameter depthwise convolutional speaker encoder, trained on English interview, telephone, and read-speech datasets. Published diarization scores use oracle voice activity detection. | Official NeMo implementation; native CoreML deployment is unmeasured here. Model weights are CC-BY-4.0. | Useful second embedding comparator; oracle-VAD results cannot establish improvement on D's observed speech detection failures. |
| [FluidAudio LS-EEND](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/LS-EEND.md) | Streaming Conformer/online-attractor labeler. Domain-specific variants have 4 AMI, 7 CALLHOME, or 10 DIHARD slots, at 8 kHz. | Native CoreML implementation exists; converted models are [MIT-licensed](https://huggingface.co/FluidInference/ls-eend-coreml). | Feasible live-labeling experiment. Finite slots still require a lifetime policy, and library documentation warns that persistent enrollment is less reliable than its embedding database. |
| [CAM++ CoreML](https://huggingface.co/FluidInference/campplus-coreml) | Approximately 7.2M-parameter, 192-dimensional embedding conversion; reported conversion tests use clean read Mandarin. | Native CPU preprocessing and ANE embedding artifacts exist. The conversion explicitly defers licensing to upstream CAM++. | Low integration-cost candidate for a future embedding test, but neither its domain nor reported verification trials establishes meeting accuracy here. |

Retain Nemotron plus the corrected current WeSpeaker encoder for this change because the measured failure involved preprocessing and grouping, and the final channel method improves the tested identity comparisons without replacing the model. This does not prove WeSpeaker is the best encoder. A future comparison should keep segment selection, trusted windows, held-out recordings, and publication rules fixed while separately calibrating each encoder. Different encoders and preprocessing revisions require separate typed embeddings and representative samples; their vectors and thresholds cannot be interchanged. Replacing an embedding model alone does not remove the live labeler's channel limit.

# Experiment setup

The initial three private recordings span below-capacity, near-capacity, and above-capacity cases. Labels from the saved worker output are anonymous reference groups, not a verified count of people. Selection was based on duration and saved label counts before running consolidation.

| Sample | Audio minutes | Saved worker labels | Purpose |
| --- | ---: | ---: | --- |
| J | 18.90 | 13 | Above eight cumulative labels |
| B | 46.18 | 7 | Near-capacity comparison |
| G | 29.45 | 3 | Initial lower-capacity control; later diagnostic |
| D | 45.28 | 5 | Fresh channel-unit validation; 10 random clips, 6 reviewed identities |
| C | 54.51 | 4 | Fresh channel-unit validation; 10 random clips, 2 reviewed identities |

D and C were selected and hash-frozen before new-method outcomes. No unused human-reviewed recording was shorter than 20 minutes or had more than eight saved worker labels; full recordings preserve the existing random review without selecting favorable subregions. B remains the calibration recording; J and G are diagnostic after their outcomes informed method changes.

Preparation verifies prepared-audio hashes, frozen annotation hashes, and exact segment timestamp multisets against retained `extraction_raw.json` artifacts. The source client writes those artifacts from completed RunPod extraction responses. Historical endpoint, worker revision, device, and timing receipts are absent, so the comparison concerns saved worker results rather than a reproducible historical deployment.

The silver reference uses raw worker speaker labels before person association. It is not ground truth. Human-reviewed random excerpts form the independent accuracy view; clips selected to cover saved speaker labels form a separate, selection-biased capacity view. An existing explicit identity adjudication is applied using its frozen annotation hash. No new labels are inferred from the consolidation result. Timestamps are not shifted or scaled to improve agreement.

The replay uses FluidAudio revision `21493f8dac5a97e65742e6ff26f42f164c2fda0f`, Nemotron's low-latency configuration, and installed Community-1 model revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`. The initial replay produced 256-dimensional unit-normalized WeSpeaker vectors with preprocessing contract `gday-span-mask-v1`. Corrected extraction uses `gday-span-feature-center-v2`: active filterbank frames are re-centered and padded features are zeroed. The two types remain incompatible. Clean spans need at least three seconds; continued speech is sampled at a five-second cadence. Eight channels each need three seconds of sustained evidence before rollover, which uses a nearby 0.3-second silence or a five-second wait limit and 45 seconds of bootstrap audio. The rejected excerpt method uses complete-link cosine admission and a 15-second propagation limit. The production channel-unit method uses explicit trusted windows. Both select three representatives.

The replay invokes the production adapter, activity filter, voice sample selector, embedding extractor, and consolidation engine. Rollover on/off runs use the same audio. Awaiting extraction eliminates the live controller's busy skips, so these runs establish ideal coverage rather than concurrent recording performance. For the corrected comparison, all 775 retained spans across six documents were re-extracted from the original WAV using the actual corrected production extractor. Sample times, IDs, quality, local labels, and activity were asserted unchanged; Nemotron was not rerun. Original evidence remains immutable.

## Methods and metrics

**Baseline:** anonymous production Nemotron activity intervals with their local identities. **Rejected excerpt method:** complete-link cosine admission over retained compatible embeddings, with representative sample selection and bounded temporal propagation. **Rollover ablation:** repeat both with rollover disabled to isolate the window policy from clustering. Unresolved activity retains an anonymous label during scoring and is counted separately.

**Production channel-unit method:** trust each source/local identity as one voice only within its explicitly recorded pre-capacity window, average that unit's corrected normalized embeddings and normalize again, then perform complete-link agglomerative clustering across units. Same-source overlapping activity creates a cannot-merge constraint. Only observed activity within the window's trusted range receives its sampled unit's cluster. Trust ends at the first establishment of eight channels; rollover-wait speech, unknown or saturated-bootstrap windows, and units without samples stay unresolved. Samples must fit wholly within the trusted range. This preserves the labeling model's within-window decisions rather than allowing individual embedding fluctuations to split them. It does not prove that an unobserved voice never changes within a channel, so the engine requires explicit provenance rather than inferring trust from UUIDs or a rollover setting. The wrapper additionally verifies successful capture receipts, unchanged original activity, and sample timing.

**Diarization error rate (DER):** missed, extra, and confused speaker-time divided by reference speaker-time, after one optimal speaker mapping across the scored sample. Against worker annotations this is annotation-relative disagreement, not accuracy. Unannotated worker gaps are excluded; independently reviewed silence contributes false alarms.

**Merge precision and split recall:** duration-weighted B-cubed scores over paired, exclusive speech. Precision falls when distinct reference speakers are merged; recall falls when one reference speaker is split. These conditional metrics exclude unpaired and overlapping regions, which remain visible in DER.

**Coverage:** the union of retained sample intervals, total predicted activity, and unresolved activity, in seconds. **Runtime:** wall time of accelerated replay, embedding extraction, and the final clustering call. Speaker counts distinguish reference labels, local generations, and voice clusters. Backlog and real-time controller drops are not measured by this harness.

# Results

All tables use zero collar and include reference overlap. Lower DER or disagreement is better. These are anonymous acoustic timeline measurements, not final transcript accuracy: publication applies additional coverage and ambiguity gates and preserves manual assignments.

## Production channel-unit method

The channel method was frozen before D/C outcomes. After the initial receipt-only experiment, all five recordings were replayed with the corrected production extractor and actual trusted-window metadata. The final production engine was compiled separately and called directly; provenance was never synthesized. The stricter cutoff was a correctness constraint, with no method or threshold tuning on D/C. On calibration B, thresholds 0.10–0.30 produced 41.23% silver disagreement; every threshold from 0.40 through 0.90 in the declared grid tied the live baseline at 40.91%. The prespecified nearest-0.72 tie rule selected 0.72. This broad plateau does not tightly identify a voice threshold; the final fresh B calibration reproduced it. No D/C threshold tuning followed.

| Recording and role | Human random DER, live → channel | Worker disagreement, live → channel | Sampled units → clusters |
| --- | --- | --- | --- |
| D, newly selected validation | 117.64% → 114.25% | 67.24% → 47.46% | 10 → 7 |
| C, newly selected validation | 19.41% → 19.41% | 21.42% → 21.42% | 3 → 3 |
| B, calibration | 15.97% → 15.97% | 40.91% → 40.91% | 7 → 7 |
| J, diagnostic capacity case | 25.78% → 25.78% | 57.99% → 52.58% | 15 → 13 |
| G, diagnostic control | 19.89% → 19.89% | 31.17% → 31.17% | 1 → 1 |

D's reviewed reference contains 95.49 speaker-seconds across 199.12 reviewed wall seconds. Its high DER is valid: live output contributes 87.14 false-alarm seconds, 12.67 missed seconds, and 12.53 confused seconds. Channel grouping leaves missed/extra speech unchanged and reduces confusion to 9.29 seconds. Conditional split recall improves from 0.770 to 0.847 while merge precision remains 0.874. Saved worker DER is also high at 75.00%. Grouping does not repair D's poor speech activity detection. A separate frozen-review audit confirmed exhaustive speech/silence instructions, completed status for all ten random clips, exact PCM identity between each clip and its source offset, and valid interval bounds. An explicit 0.885-second uncertain gap is excluded; one full random clip is reviewed silence. The earlier benchmark already reported D's high false-alarm error. No factual alignment or coverage error was found, and no scoring exclusion was changed after viewing results. This verifies metadata and alignment, not the accuracy of one reviewer's judgments.

C contains 151.88 reference speaker-seconds across 197.83 reviewed wall seconds; saved worker DER is 18.05%. It shows no changed groups or measured accuracy. D unexpectedly established enough live channels to create three generations, despite only five saved worker labels; C stayed in one generation. This exercises rollover but does not establish that D contains more than eight people.

J targeted DER improves from 47.15% to 43.01%. Because J/G informed earlier diagnosis, these are diagnostic observations only. D/C were selected before the new method's scores and constitute its first independent validation. The final table uses fresh metadata and the exact production trusted-cutoff engine. The earlier receipt-only ablation gave J/D worker disagreement of 52.19% / 47.35%, compared with the stricter 52.58% / 47.46%; human scores are unchanged. The cutoff deliberately retains uncertain rollover-wait speech as unresolved rather than assigning identities beyond supported evidence.

Pooling only D/C sums 247.37 reference speaker-seconds, 33.58 missed seconds, and 94.13 extra seconds. Confusion falls from 14.11 to 10.87 seconds, producing the 57.33% → 56.02% DER change. These are summed components, not an average of recording percentages.

Final direct replay includes corrected extraction and real window metadata:

| Sample | Generations / retained samples | Direct sample / channel-inferred / unresolved speaker-seconds | Replay seconds | Embedding seconds | Optimized final clustering seconds |
| --- | --- | --- | ---: | ---: | ---: |
| J | 3 / 82 | 260.38 / 572.13 / 36.36 | 163.66 | 12.65 | 0.0035 |
| B | 1 / 250 | 798.67 / 1465.06 / 0.00 | 378.87 | 39.96 | 0.0087 |
| G | 1 / 65 | 196.22 / 483.06 / 0.00 | 204.13 | 9.99 | 0.0027 |
| D | 3 / 113 | 373.14 / 1331.13 / 574.74 | 369.93 | 18.41 | 0.0063 |
| C | 1 / 253 | 791.57 / 1725.99 / 0.40 | 452.36 | 42.63 | 0.0110 |

These durations sum speaker-time, so overlapping voices can exceed wall time. Every final replay completed with zero capture gaps, adapter/window-provenance failures, and extraction failures. Debug replay timing and optimized standalone clustering timing are identified separately. Concurrent inference and build work prevent isolated performance claims.

## Rejected sample-level grouping: human-reviewed accuracy

| Sample and review | Saved worker DER | Live without rollover | Live with rollover | Consolidated, 0.72, rollover on | Original, frozen 0.55, rollover on | Corrected, frozen 0.20, rollover on |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| J random | 18.21% | 25.21% | 25.78% | 63.22% | 63.34% | 43.58% |
| J targeted | 46.60% | 54.41% | 47.15% | 62.59% | 78.13% | 50.79% |
| B random, calibration recording | 27.47% | 15.97% | 15.97% | 47.85% | 52.94% | 22.36% |
| B targeted, calibration recording | 35.48% | 26.53% | 26.53% | 58.35% | 58.10% | 31.29% |
| G random | 21.01% | 19.89% | 19.89% | 41.67% | 21.46% | 54.15% |

Random review covers 60, 60, and 200 wall seconds for J, B, and G respectively; reference speech is 45.73, 57.10, and 88.82 speaker-seconds. J targeted review covers 253.77 wall seconds and 205.57 speaker-seconds; B covers 140 and 126.06. G's reviewed speech contains one dominant identity, so its review is a weak test of speaker merging.

For J targeted speech, rollover changes missed/extra/confused seconds from **39.22 / 15.62 / 57.01** to **22.67 / 16.16 / 58.10**. Merge precision improves from 0.541 to 0.692 while split recall falls from 0.824 to 0.745. Rollover reduces missed speech and changes the merge/split tradeoff; evidence for better identity continuity remains mixed.

## Rejected sample-level grouping: worker comparison and calibration

| Sample | Live without rollover | Live with rollover | Consolidated 0.72, rollover on | Original frozen 0.55, rollover on | Corrected frozen 0.20, rollover on |
| --- | ---: | ---: | ---: | ---: | ---: |
| J | 62.20% | 57.99% | 77.97% | 81.47% | 63.58% |
| B, calibration | 40.91% | 40.91% | 74.46% | 67.64% | 49.62% |
| G | 31.17% | 31.17% | 39.85% | 33.85% | 55.29% |

These percentages measure disagreement with saved worker annotations, not ground-truth error. B was reserved before threshold selection. A fixed grid of 0.55, 0.60, 0.65, 0.70, 0.72, 0.75, 0.80, 0.85, and 0.90 produced B disagreements of 67.64%, 71.25%, 71.57%, 74.46%, 74.46%, 77.56%, 74.19%, 71.99%, and 70.89%. The minimum, 0.55, was frozen before applying it to J and G. It remains worse than B live output and does not generalize to acceptable held-out accuracy. The minimum occurs at the grid boundary; this is a failed candidate calibration, not evidence of an optimal production threshold.

Corrected vectors changed the similarity scale, so a new grid was declared before scoring them: 0.10, 0.20, 0.30, 0.40, 0.50, 0.55, 0.60, 0.65, 0.70, 0.72, 0.75, 0.80, 0.85, and 0.90. B silver disagreements were respectively 56.02%, 49.62%, 58.49%, 70.67%, 71.83%, 74.15%, 72.49%, 73.58%, 69.31%, 68.97%, 66.97%, 66.19%, 66.19%, and 66.19%. The selected 0.20 was frozen before evaluating G and J. G is the primary untouched control; J was used to diagnose preprocessing and is now a diagnostic comparison, not pristine held-out evidence. Every other clustering setting remained fixed.

At corrected 0.72, random-excerpt DER was 67.19%, 40.29%, and 46.34% for J, B, and G. The calibrated correction improves J and B relative to the original calibrated method, but G worsens substantially and every calibrated corrected score remains worse than its live baseline. No automatic-publication threshold was established.

## Isolating sample grouping

J's rollover-on diagnostic scores only the exact retained sample intervals. Both hypotheses therefore have identical acoustic support, with no temporal propagation or unresolved fallback. The 0.72 clusters still regress:

| Reference | Paired exclusive seconds | Local-label DER | Cluster DER | Local merge precision / split recall | Cluster merge precision / split recall |
| --- | ---: | ---: | ---: | --- | --- |
| Saved worker | 253.02 | 27.83% | 64.20% | 0.714 / 0.650 | 0.319 / 0.498 |
| Human random | 20.77 | 0.10% | 41.31% | 1.000 / 1.000 | 0.643 / 0.638 |
| Human targeted | 59.00 | 16.30% | 54.92% | 0.829 / 0.983 | 0.341 / 0.933 |

The failure exists in embedding grouping itself; changing interval propagation alone cannot explain it. Each retained sample overlaps its recorded local activity, and consolidation preserves the activity union. Four fixed chronological samples were re-extracted from the saved WAV using their retained timestamps and the production extractor. Cosine similarity to the retained vectors was 0.999926–0.999954, which rules out a material timestamp-indexing error for those samples.

A controlled preprocessing probe found that the exported filterbank centers all 998 frames, including the padded tail. The active frames retained a per-bin mean RMS of 19.09–20.54, although the full-frame means were approximately zero. Re-centering the active frames and zeroing inactive features changed pairwise cosine similarities from 0.776–0.936 to 0.069–0.507 on those four samples. This is evidence of a shared padding-related direction, not a speaker accuracy result: no new identities or threshold were fitted, and the original production scores were preserved separately from the corrected comparison. It changes the embedding compatibility contract; the full corrected comparison above separately measures accuracy. The pinned FluidAudio span helper uses the same original waveform padding and pooling-mask recipe; following that helper does not establish short-span calibration.

The corrected frozen 0.20 method also fails on G's exact retained sample support. Across 23.75 paired reviewed seconds, local labels have DER 0.24%, merge precision 1.000, and split recall 1.000; corrected clusters have DER 37.09%, precision 1.000, and recall 0.535. This isolates over-splitting even before propagation. G contains only one reviewed dominant identity, so it cannot establish behavior for many distinct speakers.

## Coverage and runtime

| Sample / rollover | Generations | Samples | Sample / activity / unresolved seconds | Clusters at 0.72 / 0.55 | Replay seconds | Embedding seconds | Debug clustering seconds |
| --- | ---: | ---: | --- | --- | ---: | ---: | ---: |
| J off | 1 | 63 | 200.41 / 723.54 / 312.55 | 7 / 2 | 147.73 | 6.16 | 0.161 |
| J on | 3 | 82 | 261.81 / 822.77 / 314.03 | 7 / 3 | 169.70 | 7.75 | 0.258 |
| B off | 1 | 250 | 803.67 / 2169.64 / 769.29 | 8 / 2 | 300.74 | 18.67 | 1.672 |
| B on | 1 | 250 | 803.67 / 2169.64 / 769.29 | 8 / 2 | 378.01 | 25.26 | 2.108 |
| G off | 1 | 65 | 198.39 / 679.28 / 80.97 | 2 / 1 | 231.56 | 6.77 | 0.274 |
| G on | 1 | 65 | 198.39 / 679.28 / 80.97 | 2 / 1 | 231.10 | 6.62 | 0.284 |

Unresolved durations above refer to 0.72. Optimized production clustering at frozen 0.55 took 0.006–0.038 seconds for these documents; different thresholds change grouping and runtime. Every completed run reported zero capture gaps, adapter failures, and extraction failures. Corrected re-extraction took 4.07 / 5.29 seconds for J off/on, 16.25 / 16.19 for B, and 4.22 / 4.19 for G, excluding model loading. Corrected 0.20 clustering took 0.006–0.024 seconds and produced 13, 8, and 2 clusters for J/B/G rollover-on; corrected 0.72 produced 71, 144, and 50. The inherited replay times above belong to the original six recordings and must not be attributed to the correction. All six complete recordings finished. B and G on/off ablations had identical acoustic timelines, sample counts, cluster counts, and accuracy scores, consistent with no capacity rollover occurring. Runtime differences are contention measurements, not evidence that the unused rollover option adds that overhead.

Inference used an isolated copied Debug test bundle and installed CoreML models, with normal local runtime permissions. Two replays and unrelated build work could contend for resources. These are accelerated replay timings, not release performance or isolated hardware benchmarks. A sandbox-constrained attempt timed out and was excluded entirely; normal-permission runs restarted from the beginning. The harness records binary, source, audio, annotation, and result hashes. It never uploaded audio or changed the meeting library.

Five synthetic scorer tests pass, covering merges, splits, reviewed silence versus unknown gaps, global mappings across clips, and unresolved activity. Three executable checks cover the original channel method's continuity, merging, overlap constraint, and provenance rejection. Optimized and Debug sample-level clustering returned identical JSON on a small real diagnostic document.

The validated trusted engine was promoted to the sole production `SpeakerConsolidation` implementation; rejected sample-level code remains only in the experiment. Rebuilding after the schema/type extraction produced exactly identical result JSON for all five final recordings and all fourteen calibration thresholds: 19 parity checks. Frozen binaries, input hashes, receipts, and previous results remain separate from the promoted build.

## Limitations and next step

The existing human review uses one reviewer and short excerpts. Targeted clips were selected using saved labels; their results do not establish population performance. Replay has ideal sequential extraction coverage, bypasses the capture queue, and does not measure controller busy skips, concurrent transcription, energy, or sustained recording backlog. Existing association corrections are validated by application tests rather than this anonymous acoustic evaluation.

Retain the corrected extractor, timed evidence, explicit trusted-window metadata, and final channel-unit engine together. Legacy evidence without trusted windows must not acquire inferred continuity. The final exact policy passes the measured non-regression comparison and reduces some identity fragmentation, while absolute speech detection errors remain large on D. Broader independently reviewed meetings, live busy-skip measurements, and transcript-publication evaluation remain necessary before claiming general quality or live performance. Full Community-1 recording analysis remains a separate option; this experiment does not show that lightweight consolidation replaces it in every meeting.
