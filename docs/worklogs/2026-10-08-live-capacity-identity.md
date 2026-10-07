---
title: Reduce live speaker identity errors across capacity rollover
date: 2026-10-08
status: in-progress
scope: live-speaker-labeling-and-evaluation
---

# Problem

The completed speaker-consolidation work improves identity grouping after recording. Its live rollover ablation reduced targeted diarization error from 54.41% to 47.15%, but confused speaker-time increased from 57.01 to 58.10 seconds. The subsequent 43.01% result belongs to after-recording consolidation. It does not prove that live identities improve across windows.

The live controller retains embeddings and exposes review suggestions. It does not reconnect fresh local identities to meeting-wide identities during recording. Automatically applying existing People matching thresholds would bypass the unresolved calibration for unknown voices.

# Design and progress

Evaluate chronological cross-window association using only embeddings available at each decision. Preserve local identity and window provenance separately from any proposed meeting-wide identity. Do not use final channel means, future overlap constraints, or reference labels to make an earlier decision. Keep unknown and unresolved activity in scoring, and report false merges, fragmentation, and decision delay alongside total error.

The existing replay records sample audio times but not callback availability. Add an ordered trace of published activity and completed embeddings, recording how much audio has been submitted at each callback. This measures causal availability under sequential replay; it cannot establish concurrent capture latency or busy-skip behavior. Bind the replay source and trace to the run receipt. Keep private traces and evidence under ignored `tmp/` storage.

The existing 0.72 threshold is the first frozen experimental candidate. Compare it with current live output and include the existing controls. Record rejected methods rather than shipping a regression. A provisional sample-end-plus-delay simulation is sensitivity analysis only; actual ordered callbacks are required before a production decision.

# Risks and technical debt

- **Evidence coverage:** sequential replay awaits extraction, while the live controller can skip samples when busy. A successful replay result requires separate controller-level coverage and concurrency validation before a live reliability claim.
- **Unknown voices:** matching to a familiar voice can falsely merge a new person. Existing People suggestions remain suggestions while this risk is uncalibrated.
- **Capacity establishment:** the current three-second continuous threshold can miss repeated short turns. Measure cumulative duration and longest runs before changing the rule; false channel proliferation can make earlier resets worse.
- **Publication delay:** activity and embeddings arrive after their acoustic timestamps. An offline reconstruction must not be reported as a live result. Actual callback order is retained for this reason.

No production shortcut or compatibility migration has been introduced in this follow-up. Experimental methods remain isolated until measured against the live objective.

# Validation

The trace instrumentation and synthetic ordering test passed in the isolated Swift test bundle. Fresh J/D model replays both completed without gaps, extraction failures, or provenance errors. Fifteen Python causal checks pass, including failure-receipt rejection and explicit policy compatibility. The isolated production release build passed with macOS 26.0 minimum and SDK 27.0. Existing Command Line Tools linker warnings about missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths remain; no deprecation warning was observed.

At actual replay publication callbacks, the frozen sticky candidate changes J targeted DER from 47.15% to 44.50%, but D random DER regresses from 117.64% to 121.28%. Do not promote immutable publication-only behavior. Applying a newly available association to the same label's earlier published rows gives final current-state snapshots of 43.01% and 114.25%, respectively. These are later corrections, not earlier recognition. B/G/C remain unchanged in estimated-availability controls. The [experiment report](../../experiments/speaker-consolidation/RESULTS.md) records methods, baseline semantics, and rejected comparisons.

Changing establishment to three cumulative active seconds would trigger J's first rollover at essentially the same time; D differs by about one second. The short-turn structural risk therefore does not explain these first-window results. No production counter change was made.

Public disjoint-speaker stress cohorts were prepared and independently reconstructed before model outcomes. Their [report](../../experiments/live-speaker-capacity/RESULTS.md) records the source, license, cohort freeze, ownership-only metrics, and development results. Nine scorer checks and four receipt/policy wrapper checks pass. The original counter delays capacity from 62.8 seconds of cumulative evidence to 141.1 seconds in the development arrivals scenario, and never resets in short turns. Unlike J's first window, these inputs expose the establishment failure directly.

A preregistered experimental counter credits runs of at least 300 ms until each channel accumulates three seconds. Four standalone Swift checks pass; the copied app also passes its existing capacity tests. Its eight development replays complete, but higher coverage and merge precision come with worse fragmentation. Reject it as a standalone change. Only an isolated replay checkout uses that counter and its distinct experimental provenance revision. This deliberate experimental source copy is a reproducibility artifact, not a shipped runtime fork; promotion must leave one production implementation.

New replay receipts bind model assets, sources, and the binary before inference and verify them afterward. A fresh public control passes with 26 stable model-asset hashes. Historical diagnostic receipts lack that asset binding and cannot authorize held-out validation. The installer rejects source-directory and file symlinks escaping its isolated package; both rejection paths were checked without changing external fixtures.

The bootstrap-context probe completed eight development replays with stable source, binary, and model-asset provenance. It preserves all published activity and admits no aliases through a saturated bootstrap. Saturation conditional confusion improves from 41.75% raw local (47.57% capacity-safe local) to 25.59%, while arrivals and short turns remain unresolved. These ownership scores are not DER or fresh fingerprint validation. Ten focused Swift tests and 24 Python checks pass. No production promotion follows from this partial result. Remaining gates are a non-regressing live method, independent new-voice rejection, causal identity/correction integration, concurrent extraction coverage, and whole-app validation of any production change. The goal remains active; the production counter and association behavior remain unchanged.

Checkpoint `5795feb` is pushed after transient GitHub server errors. macOS CI run `37696840629` is in progress. A separate risk audit is measuring consolidation and People matching costs before deciding on optimizations.
