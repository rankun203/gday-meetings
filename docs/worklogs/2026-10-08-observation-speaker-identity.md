---
title: Observation-based meeting speaker identity
status: evaluated; candidate not promoted
---

# Design and acceptance

Meeting identity belongs to time-bounded speech observations and anonymous meeting clusters. Local model channels are temporary evidence. A reviewed People identity is a separate optional association. Existing trusted-channel consolidation remains the production default until the observation candidate passes accuracy and publication validation.

The candidate must retain original source/audio timestamps and compatible embedding types, permit splitting a reused local track, permit joining fragmented tracks, preserve overlapping speakers, and avoid propagating sampled identity indefinitely through a channel. Unknown, short, or mixed speech stays represented as unresolved activity. Bounded quality/diversity-selected matching representatives are distinct from durable raw evidence and from the few examples exposed for human review. No projection coordinates participate in identity decisions.

Person naming remains downstream of acoustic clustering. Manual assignments and explicit removals must survive split/merge revisions without automatically naming every fragment of a reused local label. The Speakers panel exposes actionable labels only when associated playable embedding evidence exists.

# Evaluation plan frozen before candidate outcomes

Use the five existing corrected, trusted-window replay documents (B/C/D/G/J) as regression/development diagnostics. They have all been examined in earlier work; none is newly held out for this feature. Freeze the candidate configuration and executable/source hashes before its first evaluation. Do not silently retune after reviewing C/D and continue calling them validation.

Compare raw live activity, the exact current production consolidation baseline, and the observation candidate on identical evidence. The existing scorer reports zero and 250 ms collars, overlap included/excluded, and one speaker mapping per full sample/review category. Report random human-reviewed excerpts separately from speaker-coverage-selected excerpts. Saved RunPod worker output establishes disagreement only, not accuracy; the historical worker deployment cannot be fully reproduced because its revision receipt is absent.

Unresolved activity remains in the hypothesis under anonymous local labels; it is not dropped. This fallback is an acoustic diagnostic, not a claim that the app publishes those names. Report unresolved wall time and speaker-time separately, assignment coverage, conditional B-cubed merge precision and split recall, and missed/extra/confused speaker-seconds alongside DER. Lower error with less assignable coverage is insufficient to establish a useful improvement.

The retained-evidence evaluation does not measure live latency or causal publication. A separate causal replay must deliver embeddings at their recorded availability callbacks, never at acoustic end time or from future observations. Its prefix decisions must remain unchanged when future evidence is altered. It must quantify first-label delay, retrospective changes, queue/backlog behavior, and unresolved duration. Public LibriSpeech arrival/return fixtures provide known source ownership but include internal silence, so their ownership scores are not DER. Reserve their unused speaker cohort for a frozen policy; use development fixtures first.

Production promotion requires no unexplained loss on existing human-reviewed controls, improved capacity-related identity behavior, correct overlap and manual-edit behavior, and a bounded live processing budget. A failing experiment is retained as evidence and does not change the default.

# Reproducibility

`experiments/observation-speaker-identity/build.py` compiles shared production types and the direct Swift runner with source/binary hashes. `evaluate.py` verifies frozen evidence and reference receipts before scoring; all meeting data and detailed outputs stay under ignored `tmp/`. No audio is uploaded and no meeting library is modified.

The measured outcomes below keep the candidate opt-in. Live capture and automatically scheduled consolidation continue to use the existing policy.

# First frozen candidate: strict-support ablation

The first strict-support configuration (.72 admission, .08 runner-up margin, 12 representatives, 15-second continuity) fails the existing random human-reviewed regression set. The baseline runner exactly reproduced the previously retained production results. Zero-collar, overlap-included results follow; percentages above 100 are possible when extra speaker-time is substantial.

| Recording | Production baseline DER | Candidate DER | Baseline → candidate clusters | Candidate assignable speaker-time | Candidate split recall |
| --- | ---: | ---: | ---: | ---: | ---: |
| J | 25.780% | 51.764% | 13 → 34 | 35.17% | .5664 |
| B | 15.965% | 23.335% | 7 → 59 | 12.80% | .8795 |
| G | 19.887% | 28.519% | 1 → 3 | 4.54% | .8054 |
| D | 114.246% | 120.781% | 7 → 30 | 9.49% | .7086 |
| C | 19.406% | 23.833% | 3 → 26 | 4.66% | .8826 |

Split recall fell from .8948/.9983/1.0000/.8470/.9755 respectively. Conditional merge precision stayed approximately level or improved slightly, which does not compensate for fragmentation and low assignment coverage. Worker disagreement for J/B/G/D/C was 73.767/48.693/34.428/73.293/25.327%; these are not accuracy estimates. Standalone optimized grouping took 3–23 ms per evidence document, excluding inference, I/O, and live scheduling; this is not a full pipeline latency measurement.

Eligibility is a major confound: the candidate accepted only 38/82, 103/250, 3/65, 55/113, and 46/253 observations respectively. Its initial requirement for full sample coverage by published activity rejects many clean extraction spans. The missing observations were marked untrusted alongside window-cutoff rejects, so this field does not distinguish those causes. Sample extraction and published activity have different semantics and must be reconciled; loosening this gate requires a separately identified rerun, not replacement of these failed results. Minimum similarity against all retained representatives plus the immutable first sample also fragments variable voices. Lowering the threshold is an unvalidated hypothesis, not a fix established by these data.

Private artifacts: `tmp/observation-identity-evaluation-20261008/baseline-verified` and `candidate-final-results`. Despite the directory name, this denotes the first source-frozen candidate and is not a release endorsement. Three Python harness checks pass (binary/evidence provenance failure and unresolved retention).

# Remaining architectural work at the first candidate

This implementation establishes an opt-in experimental core and safe post-meeting publication plumbing. It does not yet replace live capture association, implement pending-observation reconsideration, provide a bounded transcript revision horizon, or establish a validated short-window segmentation provider. Same-source overlap discovered in inferred timelines is withheld, but full overlap-aware cluster constraints still need observation-local support rather than whole-label or sampled-window-only assumptions. The prototype budget is bounded; retained cluster history and matching work are not yet bounded for arbitrarily long meetings. Those limits must be designed and measured before claiming a production online identity engine. Keep the validated production default.

# Corrected positive-support candidate outcome

The strict coverage gate was corrected to require positive activity intersection: the existing clean-excerpt extraction contract permits pauses, and published activity is not an independent purity mask. The same fixed clustering parameters were rerun against a new source-hashed executable. All 763 retained observations were eligible, with zero outside-window or unsupported-activity rejections. The failure therefore remains after removing that confound.

| Recording | Production DER | Corrected candidate DER | Clusters | Ambiguous observations | Assignable speaker-time | Split recall |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| J | 25.780% | 67.194% | 71 | 7 / 82 | 38.87% | .3796 |
| B | 15.965% | 31.656% | 122 | 119 / 250 | 20.75% | .7348 |
| G | 19.887% | 36.594% | 47 | 16 / 65 | 24.43% | .6389 |
| D | 114.246% | 120.730% | 63 | 48 / 113 | 13.91% | .6961 |
| C | 19.406% | 38.568% | 147 | 102 / 253 | 18.21% | .5862 |

Conditional merge precision was .9417/.9983/1.0000/.8835/.9760. Worker disagreement was 78.348/55.262/49.287/75.535/37.301%. Optimized grouping took 13–95 ms, excluding inference and live scheduling. No claim of improved speaker recognition or production readiness is supported. The original channel baseline must remain enabled.

Private receipt: `tmp/observation-identity-evaluation-20261008/candidate-positive-support-results/evaluation.json`; it binds the executable, all compiled Swift sources, evaluation sources, evidence, references, exact configuration, result and audit hashes. The accompanying build receipt is `candidate-positive-support.build.json`. No threshold sweep was conducted. The next experiment should improve provisional evidence handling and calibrate observation-level matching on development data, then freeze the policy before using new independently annotated data. A nearest-neighbor shortcut or silent lowering of the existing threshold is not justified by these results.

# Integration and review

The app entry point accepts an explicit observation configuration and records the actual algorithm revision and settings with its result. Local track UUIDs cannot carry a person name into observation clusters. Session cluster IDs remain stable as evidence arrives; batch publication uses model- and membership-bound IDs so changed membership does not automatically inherit a reviewed name. Exact-audio reviewed examples are reapplied only to covered passages. Existing whole-label manual corrections remain protected at their current granularity; they have not been migrated to individual observation anchors.

Root review corrected the runner-up margin to include scores below the admission threshold, accepted delayed acoustic timestamps in arrival order, preserved legacy configuration decoding, and required inferred simultaneous duplicate identities to remain unresolved. Positive activity support is an evidence-presence check, not a calibrated purity score. The observation audit supplies separate unsupported-activity, outside-window and ambiguous sample IDs. Its legacy `cannotLinkUnitPairs` field counts blocked cluster comparisons in this method, rather than unique raw pairs; interpret audits by method.

[Recorded callback replay](../../experiments/observation-speaker-identity/CAUSAL.md) passed prefix checks on J and D while confirming the same fragmentation. It establishes causal sample assignment behavior, not complete live diarization or wall-clock latency.

# Integrated validation

The complete shared workspace passed 1,187 Swift tests in 206 suites (125.728 seconds of test execution), including the observation, task-publication and causal regression tests. Seven Python evaluation/admission checks passed. Changed production Swift and test files passed strict formatting lint. The existing baseline retained equivalent output and coverage across 192 synthetic configurations. Its standalone scale driver also compiled and completed workloads through 5,760 observations and 512 trusted units.

The separate search UI task remains responsible for its ongoing changes; those files are excluded from this checkpoint. All private evaluation artifacts remain ignored. Release compilation passed in 262.84 seconds; the binary links for macOS 26.0 with SDK 27.0. Only the existing missing Command Line Tools search-path warnings appeared. This validates compilation, not a new packaged-app UI or live accuracy claim.

# Development diagnosis and revised hypotheses

Work continued after the first candidate failed. On B, non-overlapping embeddings carrying the same local label have median cosine .638 (5th percentile .499), while different-label pairs have median .143 (95th percentile .311). These labels are noisy diagnostics, not human truth. A .72 minimum over every exemplar therefore rejects much ordinary within-voice variation. Worker-derived pair labels overlap substantially and cannot substitute for verified speaker identity.

`calibrate.py` tested 45 development-only policies (centroid/top-three/minimum scoring, five thresholds, three bounded local hints) and selected on B saved-worker disagreement before evaluating other previously examined recordings. Centroid .55 with margin .04 and no hint recovered B/C random human DER, but J/G/D still regressed. `refine.py` then tested pending reassignment, centroid merging, and timeline horizons on B. A 120-second horizon recovered G and nearly D, showing arbitrary short temporal expiration creates unresolved-label fragmentation. These scripts are exploratory Python hypotheses; their metrics do not establish live callback performance or exact Swift parity.

`epochs.py` tests a different unit: a local temporal epoch whose denoised rolling prototype can change. One divergent sample is held out of prototype updates; two mutually coherent divergent samples start a new epoch at the first divergent observation. The prototype uses up to twelve recent accepted vectors; post-meeting epoch means associate globally. This preserves useful local continuity without making a channel indivisible. Initial development-selected settings (.45 change, .55 new-voice coherence, .65 global mean match) recover four random-reviewed baseline scores and improve J's previously examined targeted excerpt score. D's remaining difference is caused by fixed 120-second propagation expiry, not the number of clusters: 300 seconds recovers its baseline. That observation motivates preserving dormant track continuity across silence rather than declaring a new speaker merely because wall-clock time elapsed. It does not independently calibrate a 300-second production threshold.

The first epoch probe omitted production trust cutoffs and inferred-overlap withholding. A guarded rerun adds both before conclusions; earlier exploratory outputs remain separate. Even successful post-meeting scores require actual causal live adapter validation, bounded correction behavior, and independent new evaluation before broader claims.

Guarded epoch rerun confirmed the same random-reviewed outcomes; J targeted DER remains 37.490%. This motivated the online rolling-epoch reducer now under development. Its actual arrival-order summaries and explicit cluster aliases differ from the Python post-meeting mean calculation, so a new direct Swift evaluation is required. The reviewed implementation must also transfer cannot-link constraints when clusters alias; otherwise an old overlap exclusion can disappear when its cluster ID is removed.

# Exact rolling-epoch Swift evaluation

The first direct Swift epoch reducer (.65 global admission, .04 margin, .45 change, .55 coherent change, twelve rolling vectors) reproduces random-reviewed baseline DER on J/B/G/C. J targeted DER improves to **35.312%** from the exact current production baseline **43.012%**. D remains worse at **126.418%** versus **114.246%**, so this version is not accepted.

This version measures temporal support in observed-speech seconds rather than wall-clock seconds. Its fifteen-second support budget still expires between agreeing observations. Holding the exact nine D clusters and all decisions fixed, changing only the support budget to sixty observed-speech seconds restores **114.246%**; 300 seconds and effectively unbounded support give the same reviewed score. This isolates a timeline construction failure rather than an embedding grouping failure. The principled next correction is to interpolate observed activity bracketed by matching voice evidence, while retaining bounded one-sided extrapolation and refusing bridges across contrary or unresolved observations. A larger D-tuned constant is not the selected fix.

Private exact-source results are in `tmp/observation-identity-evaluation-20261008/candidate-epoch-v2-results`; separate gap ablations use `candidate-epoch-configurable` and `epoch-D-gap*.json`. The configurable runner records the full supplied policy in every audit. Final actual live-adapter replay is a separate requirement because post-meeting interpolation can use later evidence beyond the live revision horizon.

Comparator correction: the exact current baseline runner gives J targeted DER 43.012%; an earlier informal 47.15% comparator came from a different historical comparison. All final comparisons use the current baseline receipt. The first epoch Python 37.490% and Swift 35.312% remain improvements relative to 43.012%.

D support audit distinguishes two live problems. A principal reviewed region at approximately 29:04–29:18 lies between prior same-track embedding end 26:21 and next embedding start 30:49, so a dormant established epoch can retain continuity without future evidence. Other short reviewed regions intersect tracks whose first retained embedding arrives many minutes later. A thirty-second live revision horizon cannot retroactively use those later vectors; provisional anonymous activity and post-meeting refinement are required. These intersections are not proof that every overlapping local track is a genuine speaker: D also has substantial excess activity. The audit therefore diagnoses availability and support, not independent voice identity truth.

The exact v4 bracketing/activity-constraint run retains baseline random DER on four recordings and reduces D's remaining regression to **115.600% versus 114.246%**. Missed and extra speaker-time are identical; the difference is **1.2934 confused speaker-seconds** out of 95.4945 reviewed reference speaker-seconds. These match two tail spans at approximately 44:21–44:23, after the last embedding at 42:37 and with no following embedding. Bracketing interpolation cannot fix one-sided tail expiry. J targeted DER remains **35.312% versus 43.012%**. This isolates the next semantic correction: preserve an established dormant epoch forward until contradictory evidence or an explicit continuity break, instead of making an arbitrary support budget rename its later speech.

# Exact v5 batch regression gate

The dormant established-epoch continuation correction passes the five known random human-reviewed regression comparisons. This is the exact source-hashed Swift reducer and reconstruction, not the earlier Python approximation. All compiled source hashes still matched after evaluation.

| Recording | Existing production random DER | v5 random DER | Existing targeted DER | v5 targeted DER | Assignable speaker-time |
| --- | ---: | ---: | ---: | ---: | ---: |
| J | 25.780% | 25.780% | 43.012% | **35.312%** | 87.255% |
| B | 15.965% | 15.965% | 26.527% | 26.527% | 99.999% |
| G | 19.887% | 19.887% | — | — | 100.000% |
| D | 114.246% | 114.246% | — | — | 63.404% |
| C | 19.406% | 19.406% | — | — | 99.442% |

J targeted improvement is 7.70 percentage points, on a previously examined, speaker-coverage-selected subset. It is not independent population accuracy. All random-reviewed scores match baseline; none of these five recordings is new holdout. v5 produces 16/7/1/9/3 clusters respectively. Worker disagreement is 53.452/40.907/31.166/50.443/21.795%, reported separately from human accuracy. Optimized standalone batch grouping takes 16.5–423 ms across the documents, excluding model inference and the live scheduler.

Artifacts: `tmp/observation-identity-evaluation-20261008/candidate-epoch-v5-results/evaluation.json` and `candidate-epoch-v5.build.json`. This passes the known post-meeting regression gate. Actual causal adapter results and the disjoint public speaker cohort remain separate acceptance requirements; batch interpolation and final aliases must not be presented as live-at-the-time accuracy.
