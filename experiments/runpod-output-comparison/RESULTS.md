---
title: Deployed worker output comparison results
date: 2026-10-15
status: measured
scope: experiment
---

# Findings

On identical copied audio, the updated local output agrees closely with the deployed RunPod output where both assign a single speaker: 98.19% on the microphone track and 91.51% on the system track after anonymous speaker mapping. This is conditional agreement, not accuracy. Local output still leaves substantial timed intervals unresolved; the remote worker fills every returned word label through its nearest-speaker assignment policy.

Preserving native timing fixes the earlier data loss: all 368 source rows retain timing, comprising 13,831 word spans and 989 coarser runs. All original text and 14,820 spans survive projection. The bounded edge-overlap change adds 145 uncertain assignments without altering the acoustic result. It improves coverage modestly; it does not remove the larger differences between local and remote timing or acoustic decisions.

Keep production model defaults unchanged while testing segmentation and short-turn recovery in isolation. The next useful evaluation is listening to coverage gaps and speaker disagreements, with a separate held-out set, rather than maximizing agreement with RunPod's filled labels.

# References

The repository [worker pipeline](../../apps/worker-audio-extraction/src/audio_extraction/pipeline.py) runs transcription, forced alignment, Community-1 diarization, and `assign_word_speakers(..., fill_nearest=True)`. The [handler](../../apps/worker-audio-extraction/src/audio_extraction/handler.py) returns final segments and words, not raw acoustic turns. The [Swift provider implementation](../../apps/client-macos-swift/Sources/GdayMeetings/Services/ServiceProviders.swift) defines the existing transfer and job request shapes mirrored by this client.

The installed FluidAudio `OfflineDiarizerTypes.swift` exposes segmentation step ratio, minimum embedding duration, exclusive output, zero-vote re-embedding, and clustering threshold. These are independent pipeline controls; changing the speech onset/offset settings is not a useful Community-1 powerset-model experiment. Exact dependency revision and configuration must accompany future candidate measurements.

# Experiment setup

The two original saved audio tracks were copied without transcoding. Original-before, copy, and original-after SHA-256 hashes matched. One isolated request used the existing deployed worker with `diarize: true`. Its full response and original audio copies remain in private temporary storage. No saved transcript was replaced, no results were adopted into the library, and no worker redeployment was needed.

Local output uses the freshly retranscribed native text and saved local acoustic turns. Those 960 turns exactly match the earlier local result. Before/after projection comparisons therefore hold native transcript and acoustic input fixed. Remote output uses its own recognition and alignment on the same source files, so the local-versus-remote comparison does not isolate diarization inference alone.

## Metrics

**Timed seconds** are the union of retained positive-duration transcript timing intervals within one track. They are not recording duration or ground-truth speech duration. **Speaker-covered seconds** are those timed intervals with an assigned speaker. **Unresolved-only seconds** have timing but no assigned speaker. Per-track interval unions avoid counting overlapping transcript spans twice.

**Conditional mapped agreement** compares only intervals on which both outputs supply exactly one speaker. A maximum-weight one-to-one mapping matches anonymous local and remote speaker labels using their overlap duration. Agreement is matching duration divided by that mutually single-speaker duration. The mapping is optimized on this same meeting, so it is descriptive, not a held-out generalization score. Unresolved and ambiguous intervals are reported separately rather than counted as matching labels.

# Results

## Final label coverage and agreement

| Measurement | Microphone | System audio |
| --- | ---: | ---: |
| Local timed seconds | 699.00 | 3,019.20 |
| Local speaker-covered seconds | 464.64 | 2,226.72 |
| Local unresolved-only seconds | 234.36 | 792.48 |
| Local speaker coverage of its timed intervals | 66.47% | 73.75% |
| Remote timed seconds | 1,316.98 | 3,381.34 |
| Remote speaker-covered seconds | 1,316.98 | 3,381.34 |
| Remote unresolved-only seconds | 0.00 | 0.00 |
| Mutually single-speaker comparison seconds | 442.43 | 2,157.55 |
| Matching mapped seconds | 434.41 | 1,974.44 |
| Conditional mapped agreement | 98.19% | 91.51% |

Combined agreement is 92.65% across 2,599.98 mutually single-speaker seconds. This denominator excludes local unresolved intervals. Both normalized final-label timelines have zero multiple-speaker intervals and zero simultaneous assigned-and-unresolved intervals; this does not establish that the original audio contains no overlapping speech.

The remote response contains 251 segments and 17,251 word entries; all have speaker labels. This complete assignment is consistent with its fill-nearest policy, not proof of complete or correct acoustic recognition. The substantial difference in retained timed seconds, particularly on the microphone track, requires listening: it can reflect segmentation/alignment differences, omitted text, or speech-detection behavior. These measurements do not determine which engine is correct.

## Bounded projection change

| Measurement | Before | After | Change |
| --- | ---: | ---: | ---: |
| Local attributed timing spans | 13,144 | 13,289 | +145 uncertain assignments |
| Microphone speaker-covered seconds | 442.20 | 464.64 | +22.44 |
| System speaker-covered seconds | 2,143.38 | 2,226.72 | +83.34 |
| Microphone conditional agreement | 98.24% | 98.19% | −0.06 percentage points |
| System conditional agreement | 91.59% | 91.51% | −0.08 percentage points |

All original characters and timed spans remain intact. These changes increase coverage with a small decrease in conditional agreement; listening must determine whether additional assignments are justified. A less restrictive exploratory rule would assign more fragments, but was not adopted because unsupported portions become less constrained.

## Execution and validation

RunPod reported 366.179 seconds execution and 13.431 seconds queue delay. Execution includes recognition, alignment, and diarization; it is not comparable to a local diarization-only benchmark. Remote peak memory, GPU model, and isolated diarization time were not returned by this response, so resource parity is unmeasured.

The experiment's 19 synthetic tests passed. Local projection and passage suites passed 22 tests. The isolated macOS release build passed with existing Command Line Tools linker-path warnings. The comparison harness verified source text, anchor coverage, and timing-span conservation before emitting output. The private listening page uses native audio controls and matched windows; its labels are final output labels, not acoustic turn diagrams.

# Next local tuning experiment

Do not change production defaults yet. Use the same audio hashes and fixed native timing, keep a baseline candidate, and vary one control at a time:

1. Compare segmentation step ratio `0.2` against `0.1`, leaving embedding, clustering, and projection unchanged. Measure inference time, peak process memory, acoustic speech coverage, final attribution coverage, and reviewed short-turn recovery.
2. Test minimum embedding duration `1.0` versus `0.5` seconds. Shorter examples may recover brief turns but can also produce unreliable embeddings. Check false speaker splits as well as recovered speech.
3. Separately enable zero-vote re-embedding with its existing `0.4`-second minimum. Examine affected zero-vote intervals rather than assuming it fixes all unresolved transcript fragments.
4. Inspect exclusive versus overlapping output as an evidence-retention ablation, not as a presumed coverage improvement. Genuine simultaneous speech must remain ambiguous in the final single-speaker projection.
5. Only tune clustering after listening establishes systematic speaker merges or splits. Increasing its distance threshold merges more aggressively; source-only labels alone do not justify changing it.

Select review intervals before running candidates: include early, middle, and late sections from both tracks, short interjections, known long gaps, and speaker transitions. Keep some reviewed intervals held out from parameter selection. Rank candidates by manually checked errors and resource cost; remote-label agreement is secondary evidence. Model fine-tuning remains deferred until integration effects and parameter sensitivity are separated.

# Limitations

There is no manually labeled ground truth. The deployed response exposes no raw acoustic turns, preventing a true acoustic diarization-error comparison. Local and remote transcription text and timestamp support differ. The remote assignment policy fills gaps while the local policy preserves uncertainty; comparing coverage alone rewards that policy difference. The single meeting and same-meeting speaker mapping do not establish broader quality. Private raw responses include embeddings and capabilities and must remain untracked.
