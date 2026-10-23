---
title: Speaker attribution and reference evaluation results
date: 2026-10-23
updated: 2026-10-24
status: measured
scope: offline-speaker-experiment
---

# Speaker attribution and reference evaluation results

## Findings

Checking multiple excerpts improved attribution on the four independently annotated points of the diagnostic recording: the baseline assigned one correctly and three incorrectly; both per-turn and consistency-triggered attribution assigned all four correctly. All five repetitions produced the same decisions. These are four correlated annotated points, not twenty independent trials, and the underlying acoustic boundaries remained unchanged.

The additional work cost about 1.1 seconds per approximately two-minute recording on the measured Mac. Both clusters were inconsistent, so selective checking extracted the same number of additional vectors as full per-turn matching. This fixture establishes no selective-computation savings.

The reference evaluation does not justify increasing the active cap above 12. It does identify an open-set weakness: when all references for the correct identity are removed, the current tentative policy accepts a wrong known name in 16 of 62 trials. Keep tentative acceptance and reference-set size as separate decisions. The production follow-up now matches usable turns independently; its validation is recorded below. The acoustic partition remains unchanged.

## References

[Probabilistic Back-ends for Online Speaker Recognition and Clustering](https://arxiv.org/abs/2302.09523) studies multiple enrollment utterances and reports score-calibration limitations when enrollment count varies. This motivates comparing counts and scoring methods without assuming one unchanged threshold is equally calibrated for every method.

[Attention Back-end for Automatic Speaker Verification with Multiple Enrollment Utterances](https://arxiv.org/abs/2104.01541) evaluates learned relationships among enrollment utterances. It supports testing aggregation, but does not establish an optimal count for this app's encoder or recordings.

[Pyannote speaker identification](https://www.pyannote.ai/speaker-identification) identifies clean speech quantity, recording conditions and enrollment/inference channel mismatch as recognition factors. Diversity must remain compatible with known identity and usable speech quality.

[Adaptive data normalization for speaker verification](https://www.isca-archive.org/interspeech_2023/cumani23_interspeech.html) discusses cohort-based normalization under domain mismatch. User rejections are sparse identity constraints; they are not automatically interchangeable with a representative cohort or encoder training data.

## Experiment setup

Production baseline revision: `efdd64613bad7cf2192c080f9880677f78ab0364`. Acoustic inference uses FluidAudio revision `21493f8dac5a97e65742e6ff26f42f164c2fda0f` and locally copied Community models at revision `df2625ac79a7ac6b65ad868fee6d80f320da4232`. Inputs are independent snapshots, and all private artifacts remain ignored. Exact source/model/configuration hashes accompany raw receipts.

The acoustic fixture has sparse user-annotated identities and a previously reproduced mixed-speaker partition. Reference evaluation holds out entire meetings and reports available enrollment provenance without assuming historical confirmation pathways. Definitions and reproducibility instructions are in [README.md](README.md).

## Results

### Reference counts and aggregation

The frozen library contains 62 usable confirmed representations across 20 people and 18 meetings. Fifty queries retain a reference for their person after withholding the whole query meeting; 12 do not. No record has a modern automatic-selection receipt, so historical per-excerpt confirmation versus earlier assignment pathways cannot be established. No model training occurs.

Maximum-cosine results across all 62 held-out queries:

| Reference cap | Largest actual profile | Correct automatic | Correct tentative | Wrong tentative | Abstained |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 19 | 29 | 5 | 9 |
| 3 | 3 | 20 | 28 | 5 | 9 |
| 6 | 6 | 24 | 24 | 5 | 9 |
| 12 | 12 | 25 | 23 | 5 | 9 |
| 24 | 14 | 25 | 23 | 5 | 9 |

Among the 50 supported queries, all caps produced 48 correct assignments, two abstentions and zero wrong assignments. All five wrong names occur among the 12 queries with no remaining reference for their true person. No wrong automatic assignment occurred. The median available profile has only two references for caps of three or greater. This dataset cannot establish an optimal cap of 12 or 24; the extra references mainly change which correct matches pass the existing automatic threshold.

At cap 12, applying the same uncalibrated gates to each scorer gives:

| Scorer | Correct automatic | Correct tentative | Wrong tentative | Abstained | Unknown-person false tentative accepts / 62 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Maximum cosine | 25 | 23 | 5 | 9 | 16 |
| Mean cosine | 4 | 44 | 6 | 8 | 15 |
| Mean of top three | 10 | 38 | 5 | 9 | 16 |
| Normalized centroid | 31 | 17 | 5 | 9 | 14 |

The separate unknown-person trial removes every reference belonging to the query identity as well as every reference from its meeting. No method produced an automatic false acceptance in these trials. The 16/62 tentative false acceptances with maximum scoring show that a positive nearest-person score plus relative margin is insufficient evidence of known identity. Scorer-specific calibration needs separate tuning and evaluation data; the higher number of automatic centroid matches does not establish better calibrated confidence.

A retrospective creation-order replay compares stopping at the cap with reselecting after each additional retained example. At cap one, replacement yields 49 correct assignments versus 46 for stopping. At caps of three and greater, assignment outcomes match. This is a selection ablation over surviving confirmed records, not an online enrollment evaluation: the actual confirmation/deletion chronology and attempted enrollments are unavailable.

### Negative evidence

Three explicit rejected-person pairs from three different query meetings have compatible references in other meetings. One pair scores above 0.55 and none above 0.80. This sample is too small to tune or validate a generalized negative-evidence policy. A rejection supplies a pairwise fact, not the identity of another speaker.

Production persists a veto for the exact excerpt and compatible aliases. It does not retrain embeddings or generalize the rejection to new meetings. The evaluated baseline excluded rejected profiles before ranking, which could enlarge the remaining candidate's margin. The production follow-up retains rejected profiles in the comparison and abstains when the best identity was rejected; removing an identity does not create positive evidence for another.

### Acoustic attribution and resources

The two parallel source tracks each contain 128.732479 seconds of actual decoded audio (257.464958 track-seconds total); an older recording metadata duration was shorter and is not used for throughput. The optimized Swift harness uses the production full scan, the same frozen compatible profiles and identical input/model files in each method. Enrollment excludes the query recording, enforced before inference. Three temporally separated usable turns per cluster are probed. Conflicting known identities or probe cosine below 0.55 trigger independent matching for eligible turns; the experiment uses the existing 0.80 automatic threshold and 0.08 lead. Each turn uses at most its first ten seconds. These prototype consistency settings were chosen to investigate this failure and are not calibrated production defaults.

| Method | Correct / wrong on four annotated points | Additional extraction calls | Warm wall time, median (range) | Warm process CPU | Process peak RSS |
| --- | --- | ---: | --- | ---: | ---: |
| One excerpt per cluster | 1 / 3 | 0 | 1.876 s (1.869–1.877) | 2.122 s | 331.9 MiB |
| Independent usable turns | 4 / 0 | 12 | 2.941 s (2.916–2.947) | 3.129 s | 356.3 MiB |
| Probe, then expand conflicting clusters | 4 / 0 | 12 | 2.978 s (2.929–3.018) | 3.129 s | 333.9 MiB |

All methods perform the baseline's two selected-excerpt extractions. The alternatives therefore extract 14 unique excerpts in total. Both clusters trigger expansion, explaining the lack of adaptive savings. A separate negative-only annotated point violates its rejected identity under the baseline and avoids it under both alternatives; the alternative identity lacks independent human confirmation and is not counted as correct.

All 15 scans reproduce the same 21 sorted acoustic turns. The baseline names all 21; the alternatives name 13 and abstain on eight: seven have less than two seconds of usable speech, and one longer turn has only a 0.011 lead, below 0.08. No attempted extraction fails. This measures identity attribution over unchanged acoustic segments, not improved speech detection, overlap handling or full diarization error rate. A long internally mixed turn can still inherit an inappropriate identity from its first ten seconds.

Hardware: Apple M1 Max, MacBookPro18,4. One isolated release test process per method, fixed method order, five repetitions sharing model state. Table medians/ranges use the four warm repetitions. Model acquisition takes 0.163 / 0.126 / 0.137 seconds; first-inference totals are 2.032 / 2.976 / 2.966 seconds in table order. The extra audio preparation, extraction and matching costs are included; model acquisition and compilation are separate. Warm scan medians are 1.876 / 1.863 / 1.862 seconds, and incremental medians are 0.001 / 1.078 / 1.093 seconds.

RSS is the process-lifetime high-water mark, not an incremental allocation or accelerator-memory measurement. Small differences between methods do not establish memory savings. CPU excludes accelerator/system-service work; no energy claim is made. The workstation is shared, operating-system and Core ML caches are uncontrolled, and first inference is only process-cold. Compilation excludes unrelated test files from the isolated harness target; the original package manifest and file mode are restored afterward.

A separate serial Python/NumPy run evaluates 60 cap/selection/scorer configurations and 20 unknown-person configurations in 35.916 seconds wall and 35.603 seconds process CPU, with 57.5 MiB process peak RSS. Cap-12 maximum scoring takes a median 0.466 ms and p95 0.551 ms per cached query across 1,240 calls. This includes Python array/scoring overhead and excludes audio decoding, embedding extraction, app publication and profile preparation. It is not a Swift app latency measurement. Input loading and profile preparation are separately recorded in the raw receipts. Python 3.13.0 and NumPy 2.5.4 ran with BLAS thread limits of one.

### Production turn attribution validation

The production follow-up retains each detected cluster for transcript organization and manual naming, while extracting and matching each usable acoustic turn independently. A turn needs at least two seconds of speech, uses at most its first ten seconds, and abstains when detected overlap or unusable PCM prevents extraction. Full turn support is retained separately from the bounded excerpt. Human assignments remain authoritative; machine predictions remain outside confirmed reference profiles. This changes identity attribution, rather than the acoustic segmentation algorithm.

Optimized release checks used independent copies of the original diagnostic recording and four completed recordings from the latest-20 trial fixture. The additional recordings include one approximately 35-minute recording. Ten source-track hashes remained unchanged, and all 22 model/data assets matched the frozen model manifest; model loading refreshed only its validation receipt. Each query meeting was excluded from reference enrollment. Raw vectors, receipts and reconstructed reference records remain ignored.

| Recording | App-reported track-seconds | Acoustic turns | Usable vectors | Scan and extraction wall | Process CPU | Process peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Original diagnostic, two repetitions | 257.45 | 21 | 14 | 2.72–2.79 s | 2.88–2.94 s | 327–338 MiB |
| Short recording A | 53.50 | 4 | 2 | 0.64 s | 0.64 s | 338 MiB |
| Short recording B | 239.80 | 27 | 17 | 2.99 s | 3.05 s | 374 MiB |
| Short recording C | 322.89 | 16 | 5 | 2.32 s | 2.84 s | 385 MiB |
| Approximately 35-minute recording | 4227.74 | 499 | 307 | 47.91 s | 51.25 s | 626 MiB |

Times exclude compilation and model acquisition. App-reported track-seconds sum both source tracks; they are separate from decoded sample-count durations used to bound the actual excerpts. Runs share one test process, so RSS is a cumulative high-water mark rather than independent per-recording memory or accelerator usage. A shared workstation, uncontrolled operating-system/Core ML caches and few repetitions limit comparison with the original five-repetition experiment. The saved acoustic turns and vectors supply reproducible follow-up checks without repeating model inference.

Both diagnostic repetitions correctly attribute all four independently annotated points. The additional recordings have no independent identity annotations, so their coverage and resource results establish no accuracy estimate. All per-turn candidates survived persistence with their full attribution support, and none became confirmed reference evidence. A real fractional-start regression initially discarded every diagnostic candidate despite 14 valid vectors; allowing one sample of boundary snapping repaired ingestion and now has synthetic regression coverage.

The long recording writes 307 canonical example/representation pairs totaling 2.77 MB, excluding immutable analysis and discovery-cache artifacts. Initial synchronous candidate publication took 0.462 seconds. A follow-up release run reused identical saved vectors, retained original reference identifiers, and replaced repeated upsert scans with indexed lookup. Publication then took 0.447 seconds and cold matching took 0.241 seconds; these single measurements establish no meaningful causal speedup. The approximately 0.45-second main-actor publication remains a responsiveness cost, distinct from the background model work.

Review eligibility is bounded independently of attribution vectors. The 307 long-recording vectors provide 11 detected-cluster review representatives and 11 review groups; selecting and grouping them took 3.68 milliseconds in the optimized sampling snapshot. The final exact-audio alias check was added afterward and verified separately with synthetic regression tests. Explicit human decisions remain available, sampled-out turns never become hidden group-confirmation members, and another independent turn can surface after review. Existing exact-audio vetoes prevent a reviewed alias from occupying the next review slot. Review selection does not declare a mixed acoustic cluster to be one identity. The same bound applies to Existing Samples and the associated-sample list/counts on a person's profile, while retaining every distinct authored confirmation. A 1,200-turn synthetic fixture supplies four automatic review inputs without changing any attribution record. Manage Samples remains a complete stored-evidence inventory, including sampled-out turns and ignored or rejected records, so maintenance and restoration stay available independently of the listening queue.

The review cap bounds each proposal snapshot. Optional review can advance to another excerpt. Suppressing further excerpts based on a prior confirmation needs separate evaluation, including minority identities within mixed clusters.

The cached follow-up preserves every assignment outcome and both four-point diagnostic results. It measures ingestion, matching and review selection, not inference latency. Exact source, harness, input, model and configuration receipts distinguish the inference snapshot from the review/indexing snapshot; no current-build timing is inferred from cached outputs.

### Validation and review

The NumPy maximum-cosine implementation reproduces 40 saved Swift person scores within 6.7e-16; all 20 cap-12 selected profile sets match the production receipt. Thirteen synthetic Python tests and three optimized Swift policy controls passed. The measured harness hash matches the final source; scoped Swift formatting, Python syntax and whitespace checks pass. Both input audio hashes remain unchanged, and copied model assets match their pinned source files. Existing Command Line Tools linker search-directory warnings remain in the release build. Synthetic tests cover whole-meeting holdout, unknown identity exclusion, score arithmetic, selector ties, missing profiles, contradictory duplicate evidence, enrollment provenance and invalid quality receipts.

Claude Code started with `claude-opus-5-5` but stopped with HTTP 429 `usage_limit_reached` before returning review findings. The requested external review remains incomplete. A separate read-only source review identified missing harness-enforced enrollment holdout and incomplete PCM quality-receipt validation; both were addressed. Parent review also tightened stale-output checks and prevented a stale prebuilt harness from being mislabeled as the current source.

## Limitations

A diagnostic recording selected because it failed cannot establish general diarization accuracy. Sparse identity annotations cannot measure missed speech, false alarms or full-recording DER. Confirmed library examples are useful evaluation labels but are user-selected rather than a random speech sample. Automatic enrollment provenance and same-meeting leakage must be accounted for. Timing on a shared workstation does not establish energy use or hardware-independent performance.
