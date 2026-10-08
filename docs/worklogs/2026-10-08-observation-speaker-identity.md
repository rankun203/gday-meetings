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

# Remaining architectural work

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
