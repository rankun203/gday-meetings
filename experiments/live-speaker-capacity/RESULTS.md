---
title: Public speaker capacity validation results
date: 2026-10-08
status: development-measured
scope: live-speaker-capacity-experiment
---

# Findings

This experiment prepared eight recordings using public speakers in two disjoint cohorts, totaling 18.96 minutes. Initial development replay exposes delayed capacity detection and a tradeoff between recovering new voices and fragmenting returning voices. Validation remains untouched. Nine synthetic scorer checks pass, including per-owner and per-turn coverage with one global identity mapping.

Known source ownership makes identity mistakes inspectable without inferring whether voices from unrelated private recordings are different people. It does not provide exact speech boundaries. Conditional identity scores must be reported with coverage, ambiguous output, and injected-silence activity; a method can otherwise appear better by dropping difficult speech.

# References

[OpenSLR SLR12](https://www.openslr.org/12) provides the test-clean archive, official checksums, and CC BY 4.0 licensing. The [LibriSpeech paper](https://www.danielpovey.com/files/2015_icassp_librispeech.pdf) describes 16 kHz read English speech and forty speakers in test-clean. The [OpenSLR dataset card](https://huggingface.co/datasets/openslr/librispeech_asr) defines speaker and utterance IDs. These are source identities, not identities inferred by the tested labeler.

The [existing retained-embedding experiment](../speaker-consolidation/RESULTS.md) found that rollover changed the merge/split tradeoff, while after-recording channel grouping reduced some fragmentation. Its private diagnostic examples informed method development. The present frozen public inputs provide a separate controlled check; they do not erase that development history or establish natural-meeting generalization.

# Experiment setup

Preparation uses the official test-clean archive with MD5 `32fa31d27d2e1cad72775fee3f4849a9`. It checks that value against the downloaded official checksum list and computes a separate archive SHA256. Selection uses a fixed seed and SHA256 ordering of speaker IDs. Twelve speakers form development and twelve different speakers form validation. Both cohorts and all schedules are frozen before outcomes.

Utterances are selected by deterministic hash order from recordings at least eight seconds long. Each appearance within a scenario uses a different utterance. Crops are centered and have fixed durations. The same source pool may appear in different scenarios, which supports paired schedule comparisons but does not make those scenarios independent samples. Source transcripts are not used. Crops have a fixed gain of 0.9; simultaneous crops each have gain 0.45. Output is mono 16 kHz PCM16. No normalization, VAD, or model score influences selection.

| Scenario | Construction | Intended test |
| --- | --- | --- |
| Arrivals and returns | Twelve initial eight-second turns, then eight returns, with 0.5-second gaps | New people after capacity, early and late returning identities |
| Short turns | Three eight-speaker cycles of 1.5-second turns, four newcomers, then longer returns | Whether repeated short activity establishes capacity; association after samples become available |
| Saturation and rearming | Two eight-speaker cycles of four-second turns, a reduced recent population, then newcomers and a return | A replay horizon that initially contains eight voices, followed by a population change |
| Six-speaker overlap control | Two six-speaker cycles, then six simultaneous pairs | Below-capacity behavior and known conflicting identity ownership |

Scenario names express their construction, not a guarantee of observed model behavior. Internal pauses can prevent three continuous seconds of model activity even in a four-second crop. The saturated scenario only establishes a saturated model bootstrap if the measured channels confirm it; do not infer that condition from the schedule.

## Metrics

**Conditional identity confusion** scores only time with exactly one source owner and exactly one predicted label. One maximum-weight, one-to-one label-to-owner mapping is fitted across the entire recording on this same support. Confusion is the fraction of paired time whose mapped label is a different owner. This includes fragmentation penalties from one-to-one mapping, but excludes predicted overlap and absent output. It is not DER.

**Merge precision and split recall** are duration-weighted B-cubed scores on that paired exclusive support. For each owner/label cell with duration `v`, precision accumulates `v² / label total` and recall accumulates `v² / owner total`, then divides by all paired duration. Merging owners lowers precision; splitting an owner lowers recall. Report `pairedExclusiveSeconds` alongside both.

**Ownership coverage** is the fraction of time with any source crop present that has any model activity. It does not distinguish actual silence inside a crop from missed speech. Multiple predicted labels during exclusive ownership are reported separately in seconds, rather than silently counting those regions as correct or omitting them without disclosure.

**Ownership breakdowns** retain the same recording-wide identity mapping for each owner and placement. First appearances and returns are also grouped by whether the owner arrived among the first eight or later. Correct exclusive ownership coverage divides correctly mapped, singly labeled time by placed time; dropped and ambiguous output earns no credit. This prevents an apparently low conditional confusion score from concealing absent output for newcomers. Overlap recovery remains a separate metric.

**Injected-silence activity** is predicted activity in gaps where no source crop is present. These inserted regions are digital silence. Report its seconds and fraction of injected silence. Internal source pauses are excluded from this measure.

**Overlap owner-set precision and recall** reuse the mapping fitted on exclusive paired regions. During simultaneous source placement, matched owner-seconds are the duration-weighted intersection of mapped predicted labels with the known owners. Precision divides by predicted label-seconds; recall divides by placed owner-seconds. An unmapped label receives no credit. These measure source-owner recovery during constructed overlap, not detection of independently annotated simultaneous speech.

# Results

No production behavior has been changed by this experiment. The preparation manifest and ownership references remain frozen. The initial model comparison uses the production counter and the experimental sticky 0.72 association policy. All eight initial development replays, with rollover off/on, completed without gaps or extraction failures. Independent validation remains untouched.

| Development scenario | Conditional confusion, rollover off / on | Sticky publication / final alias snapshot | Ownership coverage, off / on |
| --- | ---: | ---: | ---: |
| Arrivals and returns | 26.93% / 15.36% | 19.27% / 17.45% | 83.67% / 83.49% |
| Short turns | 17.00% / 17.00% | 17.00% / 17.00% | 76.13% / 76.13% |
| Saturation and rearming | 3.21% / 40.37% | 38.63% / 30.18% | 80.37% / 83.72% |
| Six-speaker overlap control | 0.20% / 0.20% | 0.20% / 0.20% | 95.39% / 95.39% |

These conditional percentages are not DER and cannot be interpreted without coverage. In the saturation scenario, first appearances after the eighth owner have only 15.92% coverage without rollover, and none of that output maps correctly under the global mapping. Rollover raises that coverage to 36.50%, with 31.29% correct exclusive ownership coverage. Conversely, returning original owners fall from 93.13% correct coverage without rollover to 44.49% with rollover; the alias snapshot recovers only 57.03%. The low 3.21% aggregate conditional confusion therefore does not establish successful recognition of all twelve speakers.

The first arrivals window accumulates three active seconds on all eight channels by 62.8 seconds, but the continuous-run policy reaches capacity only at 141.1 seconds. Short turns accumulate that evidence by 34.36 seconds and never trigger rollover during the 99.6-second recording. This motivated the [preregistered credible-run counter](CAPACITY_POLICY.md). Its comparison changes establishment alone while retaining the frozen association threshold and scoring definitions.

## Credible-run counter ablation

The candidate credits runs of at least 300 ms until each channel accumulates three seconds. All eight candidate development replays completed without gaps or extraction failures. The copied build records a distinct experimental policy revision; production files were not changed.

| Development scenario | Generations, original / candidate | Raw conditional confusion, original / candidate | Alias snapshot confusion, original / candidate | Ownership coverage, original / candidate |
| --- | ---: | ---: | ---: | ---: |
| Arrivals and returns | 2 / 4 | 15.36% / 38.93% | 17.45% / 35.52% | 83.49% / 87.03% |
| Short turns | 1 / 3 | 17.00% / 31.97% | 17.00% / 38.38% | 76.13% / 83.96% |
| Saturation and rearming | 2 / 7 | 40.37% / 41.75% | 30.18% / 34.54% | 83.72% / 89.96% |
| Six-speaker overlap control | 1 / 1 | 0.20% / 0.20% | 0.20% / 0.20% | 95.39% / 95.39% |

Reject this counter as a standalone production change. It recovers more activity and improves merge precision, but creates enough identity fragmentation to worsen every above-capacity scenario. In short turns, the second window begins at 39.94 seconds with a bootstrap capacity timestamp of 34.44 seconds; it has no trusted continuation before the next handoff at 80.26 seconds. Reconnecting that entire window by assumption would bypass the stated capacity policy.

The next diagnostic asks whether explicitly retained bootstrap context can connect trustworthy old and new local identities at handoff. Temporal correspondence over shared audio is a separate capability probe; it is not yet a fresh-embedding association policy. Short-turn sampling and saturated bootstrap remain unresolved design constraints. No validation outcome has informed this next step.

## Replay provenance

The initial diagnostic receipts bind replay source, binary, policy, inputs, and outputs, but do not contain external model-asset hashes or a before/after stability check. They cannot authorize a frozen validation run under the stronger gate. New receipts hash the compiled model assets and sources before inference and require the same hashes afterward. Only the known mutable model-validation receipts, preparation marker, and Finder metadata are excluded from asset hashing; they are not model inputs.

A smoke run correctly detected that the app rewrites its validation cache during model acquisition. That attempt remains marked invalid and is excluded from measurements. After separating operational cache files from model inputs, a fresh public control completed with 26 bound asset files and stable provenance. Validation requires these complete runtime bindings and a matching development method for each rollover mode. Four wrapper checks cover changed executables, mixed implementations, absent asset provenance, and unstable inputs.

| Prepared scenario | Recordings | Seconds per recording | Distinct owners per recording |
| --- | ---: | ---: | ---: |
| Arrivals and returns | 2 | 170.0 | 12 |
| Short turns | 2 | 99.6 | 12 |
| Saturation and rearming | 2 | 158.2 | 12 |
| Six-speaker overlap control | 2 | 141.0 | 6 |

The selection receipt SHA256 is `a31e897ac3e36f993ed7403e5338d439f606abc35b98a9da61a775df9b18b65c`. It was written before rendering and any model execution. Preparation completed with the verified official archive and source license/README retained locally. No transcript content was copied into the repository.

The independent reconstruction pass verified all eight recordings against archive bytes, source crop bounds, speaker IDs, output placements, and manifest hashes. Every injected gap is digital zero. Maximum reconstruction error is `0.000028992`, below one PCM16 quantization step (`1 / 32768`). Each overlap control contains 36 seconds of simultaneous source placement. The validation environment used NumPy 2.5.3, SoundFile 0.14.0, and libsndfile 1.2.2. The manifest SHA256 is `e5ca6337d00ac5bc246ed6bdc091aa12db61f709ccf5e43c6f8fc1ac69969838`.

## Limitations and technical debt

The primary limitation is the absence of reviewed speech/silence masks. Source placement is exact, but internal pauses and vocal delivery remain natural. A later DER evaluation requires independent activity annotation; applying model VAD as its own reference would introduce circular evaluation.

Read audiobooks, abrupt edits, fixed gains, and artificial overlap do not reproduce room acoustics, microphone changes, natural interruptions, or ASR timing. The twelve-speaker cohorts are small, and repeated scenarios reuse speakers and source utterances. Report per-scenario results and cohort membership rather than treating each frame or schedule as an independent statistical sample.

The experiment retains no production shortcut or migration bridge. Its scorer deliberately depends on the existing assignment implementation; changes to that implementation require rerunning scorer checks and recording its source hash with final evaluations. Model execution, callback availability, and live backlog remain separate validation tasks.
