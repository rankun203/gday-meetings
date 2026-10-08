---
title: Clean short-turn evidence with explicit physical support
status: preregistered engineering hypothesis
scope: development only; not production activation
---

# Fixed question

Can the credible-eight / 12-second-bootstrap / explicit-provisional identity candidate recover short-turn fingerprints without weakening voice purity or treating an entire local channel as one person?

The preceding receipt-bound actual adapter produces source-ownership confusion 13.137%, 33.012%, 21.834%, and 0.200% on arrivals, short turns, saturated rearm, and the six-speaker control. The original v1 comparator is 15.355%, 17.000%, 40.368%, and 0.200%. Short turns are the remaining regression. No validation cohort has been examined. This is a new frontend hypothesis, not threshold tuning on ownership labels.

# Engineering policy to implement before inference

Preserve the existing contiguous three-second sample path and clean posterior gates: selected channel at least 0.7, every other channel below 0.2. Retain completed clean runs of at least 300 milliseconds and less than three seconds; the minimum matches the existing credible-channel run floor. Apply no extra edge trim beyond the existing posterior gates. Retain these otherwise-too-short clean fragments only for the same source, local label, and streaming generation while local continuity is trusted. Never combine different channels, sources, model windows, overlapping speech, or known capture gaps.

A fragmented sample requires at least two seconds of real clean PCM; use all retained support up to the six-second cap rather than padding or truncating to exactly two seconds. Two seconds is the extractor's existing supported minimum. Accumulate only within the most recent 30 seconds of recording time, matching the live revision horizon. Bound state to eight support spans and six seconds of PCM per local label; evict oldest evidence deterministically. Consume evidence once, in acoustic order, and preserve the existing five-second sample spacing. Expire the accumulator when capacity exhausts local trust, the state rolls over, capture gaps invalidate continuity, or recording stops. Do not fill gaps with other voices or invented silence.

The 30-second, eight-span, and six-second limits are engineering bounds chosen before model outcomes. They are not fitted to reference owners. If implementation reveals a necessary contract correction, record it here before inference and preserve previous results as a separate experiment.

# Explicit evidence contract

Concatenating clean PCM is an experimental embedding input, not a claim of continuous speech. Persist the actual ordered nonoverlapping support spans, source, local label, generation, total clean duration, and method revision. Bounding start/end values are insufficient provenance. Maintain typed embedding compatibility without inventing a new trained model identity.

Eligibility, speaker overlap constraints, activity support, profile independence, sample deduplication, projection, and representative playback must use these support spans. Gaps inside a fragmented observation must never count as that speaker's activity. No automatic People identity may be inferred from an unsupported gap. Human review must play real supported excerpts or an explicitly identified concatenation, not an unrelated bounding audio interval. Ordinary historical single-span records remain readable and preserve their behavior.

# Evaluation and acceptance

Build and freeze the isolated exact frontend, collector, core, and adapter code. Run tests for capacity/gap/generation resets, bounded accumulation, consumed-support exclusion, malformed or overlapping span rejection, and unchanged contiguous sampling. Preserve original input/audio/source/model hashes and callback availability.

Run fresh inference on all four development recordings, then the actual bounded live adapter. Compare the original v1 baseline, the frozen 12/off candidate, and the new candidate on the entire timeline. Report mapped ownership coverage, paired coverage, merge precision, split recall, first/return and after-eight strata, ordinary versus fragmented sample counts, owners with independent supported fingerprints, support durations, pending time, and publication versus settled identity. These ownership fixtures are not human DER. Preserve the known private reviewed regressions separately and distinguish RunPod disagreement from accuracy.

Do not discard unresolved speech, change reference mappings by stratum, or relabel inputs as a different production policy. Freeze a successful complete policy before running the untouched validation cohort. If short-turn accumulation causes false merges or regresses the controls, retain the failed result and diagnose the acoustic support; do not silently lower similarity thresholds.
