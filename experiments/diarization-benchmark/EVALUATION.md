---
title: Evaluate speaker labels against reviewed audio
date: 2026-10-01
status: experimental
scope: standalone-diarization-evaluation
---

# What the comparison measures

Saved server output is a useful baseline, but agreement with it cannot establish that a local model is better. An independent audio annotation provides a common reference for the server and both local models. Person assignments help interpret existing labels; they do not prove that every speech boundary or speaker assignment is correct. These models group voices into speaker labels. Recognizing a named person is a separate capability and needs its own enrollment and identity evaluation.

# Reference procedure

1. Select the same source track for every system. Avoid mixing microphone echo into a system-only comparison. Preserve the original files and record decoded duration and hashes. Compare saved server annotations only when they refer to that track and timeline.
2. Freeze model revisions, thresholds, preprocessing, and clip-sampling seed before reviewing quality. Keep tuning clips separate from evaluation clips. Do not give one model the known speaker count unless every system uses that same condition.
3. Sample nonoverlapping clips across the recording without consulting any system output. Present anonymous clips without transcript text, names, or predicted labels. Annotate all audible speech, overlapping voices, and silence in the reviewed region. Use consistent anonymous speaker IDs across clips from the same recording. Mark uncertain regions as unreviewed rather than guessing.
4. Separately select disagreements for diagnosis. They can reveal corrections or regressions, but their selection bias makes them unsuitable for a headline error rate.
5. Have a second reviewer check ambiguous intervals and a subset of the independent sample. Resolve disagreements before freezing the annotations. Preserve both revisions privately.

# Scoring

`score_review.py` compares every system with the same reviewed regions. Unlike the saved-transcript agreement score, it counts predicted speech during reviewed silence as a false alarm. It finds one speaker permutation for the complete reviewed set from a recording, so changing identity between clips can count as an error.

Report missed speech, extra speech, and speaker confusion, plus their sum divided by reference speaker-time (diarization error rate). Report zero tolerance and ±250 ms boundary exclusions, with overlap both included and excluded. The explicit tolerance is a half-width; libraries may use a different collar convention. These components and evaluation-region controls follow the [pyannote metrics definitions](https://pyannote.github.io/pyannote-metrics/reference.html).

Show paired local-minus-server differences on the same reviewed regions and per-recording results. A lower error rate supports improvement on that reviewed sample. Four selected meetings do not establish general superiority. A broader claim needs held-out meetings, room and remote-call conditions, and uncertainty estimated by resampling whole meetings rather than correlated audio frames. No superiority margin or confidence claim is inferred from unreviewed outputs.

For live evaluation, preserve each output's availability time. Score the labels that were available at a fixed delay, separately from final revised labels. Report delay, missing labels, identity changes, and revisions. Offline quality alone does not prove live quality, and independently remapping every rolling window would hide identity instability.

# Private artifacts

Meeting identifiers, names, content, manifests, waveforms, annotations, prediction timelines, and review keys belong in Git-ignored `tmp/` or outside the checkout. Never force-add those files. Commit generic tools, synthetic tests, and aggregate measurements only. The review key reveals source coordinates and predictions; keep it separate from the blinded annotation task.
