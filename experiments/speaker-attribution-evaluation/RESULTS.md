---
title: Speaker attribution and reference evaluation results
date: 2026-10-23
status: measured
scope: offline-speaker-experiment
---

# Speaker attribution and reference evaluation results

## Findings

Checking multiple excerpts improved attribution on the four independently annotated points of the diagnostic recording: the baseline assigned one correctly and three incorrectly; both per-turn and consistency-triggered attribution assigned all four correctly. All five repetitions produced the same decisions. These are four correlated annotated points, not twenty independent trials, and the underlying acoustic boundaries remained unchanged.

The additional work cost about 1.1 seconds per approximately two-minute recording on the measured Mac. Both clusters were inconsistent, so selective checking extracted the same number of additional vectors as full per-turn matching. This fixture establishes no selective-computation savings.

The reference evaluation does not justify increasing the active cap above 12. It does identify an open-set weakness: when all references for the correct identity are removed, the current tentative policy accepts a wrong known name in 16 of 62 trials. Keep tentative acceptance and reference-set size as separate decisions. Production behavior is unchanged.

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

Production currently persists a veto for the exact excerpt and compatible aliases. It does not retrain embeddings or generalize the rejection to new meetings. Rejected profiles are excluded before ranking, which can enlarge the remaining candidate's margin; any future calibration should retain the original comparison context rather than mistake removal for additional positive evidence.

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

### Validation and review

The NumPy maximum-cosine implementation reproduces 40 saved Swift person scores within 6.7e-16; all 20 cap-12 selected profile sets match the production receipt. Thirteen synthetic Python tests and three optimized Swift policy controls passed. The measured harness hash matches the final source; scoped Swift formatting, Python syntax and whitespace checks pass. Both input audio hashes remain unchanged, and copied model assets match their pinned source files. Existing Command Line Tools linker search-directory warnings remain in the release build. Synthetic tests cover whole-meeting holdout, unknown identity exclusion, score arithmetic, selector ties, missing profiles, contradictory duplicate evidence, enrollment provenance and invalid quality receipts.

Claude Code started with `claude-opus-5-5` but stopped with HTTP 429 `usage_limit_reached` before returning review findings. The requested external review remains incomplete. A separate read-only source review identified missing harness-enforced enrollment holdout and incomplete PCM quality-receipt validation; both were addressed. Parent review also tightened stale-output checks and prevented a stale prebuilt harness from being mislabeled as the current source.

## Limitations

A diagnostic recording selected because it failed cannot establish general diarization accuracy. Sparse identity annotations cannot measure missed speech, false alarms or full-recording DER. Confirmed library examples are useful evaluation labels but are user-selected rather than a random speech sample. Automatic enrollment provenance and same-meeting leakage must be accounted for. Timing on a shared workstation does not establish energy use or hardware-independent performance.
