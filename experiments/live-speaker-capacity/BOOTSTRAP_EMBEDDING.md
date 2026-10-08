---
title: Bootstrap headroom and fresh voice embeddings
date: 2026-10-08
status: experimental
scope: live-speaker-capacity-experiment
---

# Question and fixed comparison

Does a shorter replay suffix leave capacity for new voices, and do freshly extracted bootstrap voice samples reconnect returning voices? The temporal correspondence probe did not establish fingerprint identity. This experiment keeps that distinction explicit.

Use a two-by-two development comparison with the existing credible-run capacity counter:

| Replay suffix | Bootstrap embedding extraction |
| --- | --- |
| 45 seconds | Off |
| 12 seconds | Off |
| 45 seconds | On |
| 12 seconds | On |

The 12-second suffix is an engineering hypothesis, not a calibrated production setting. Eight channels each requiring three seconds need 24 seconds of exclusive activity; 12 seconds is half that duration. Overlapping activity can still fill eight channels within 12 seconds. Report saturated bootstrap windows and their unresolved continuation instead of treating the shorter suffix as guaranteed headroom.

The physical PCM history remains 45 seconds, including after rollover. The capacity counter, establishment evidence, 45-second rearm observation, handoff timestamp, publication clipping, and ordinary post-handoff sample selection remain unchanged. Only the audio suffix submitted to the new streaming state changes. No cold-start retry or adaptive horizon is part of this comparison.

# Fresh sample selection

With extraction enabled, each new local label can offer one initial bootstrap crop. The crop uses real contiguous PCM, contains at least two and at most six seconds, and passes the existing confidence gate: one channel at least 0.7, all others below 0.2. The existing corrected extractor supports two-second input. Do not concatenate turns, add artificial audio, reuse an old embedding under a new label, or relax its typed preprocessing contract.

A crop must fit in retained audio and in the new state's context interval before the handoff. Its end cannot exceed the new state's first known capacity timestamp. Old-window capacity does **not** invalidate the new model's bootstrap sample: the new model may label audio that the old model could no longer label reliably. Old-window capacity still constrains old profile members and temporal correspondence evidence.

The adapter's `replaying` flag is not an eligibility boundary: buffered model output may describe pre-handoff audio after replay has returned. Selection uses recording timestamps. Bootstrap selection has its own one-sample-per-label state and does not change the ordinary sampler's clean-run or cooldown state.

# Separate evidence and availability

The copied collector writes availability schema 3, retaining schema 2 context and publication callbacks. `bootstrapEmbeddingReady` entries reference IDs from `bootstrap-embeddings.json`, never ordinary `evidence.json` samples. Each separate record includes generation, context origin, handoff, first known new-window capacity timestamp, capacity policy, and a typed embedding with its original timed audio span. A ready callback follows completed extraction and uses the same ordered submitted-audio clock.

The trace and separate embedding document record both comparison settings. Record extraction time, offered/completed samples, and failures. Any extraction failure remains visible in the replay's failure totals. Bootstrap context and embeddings never append published activity or extra scored audio. A saturated bootstrap with capacity reached at or before handoff provides zero trusted continuation even when it produced a valid earlier crop.

# Causal identity comparison

Keep the existing 0.72 association threshold fixed for this comparison. It is a diagnostic threshold, not a calibrated confidence. Candidate scoring uses only embeddings available at that callback and compatible, previously trusted profile members. Preserve scores, runner-up margins, readiness timestamps, and rejection reasons for later development analysis. Reference owners never enter sampling or identity decisions.

Exclude overlapping physical audio from prior fingerprint anchors. Two extractions of the same recording span are not independent voice confirmation. Before profile means, keep deterministic nonoverlapping anchors within each prior identity: ordinary published samples take precedence, followed by recording start and sample ID. Reextracting context cannot add duplicate physical support or change profile weight through repeated copies. Report duplicate-support exclusions separately. Report excluded anchors and cases with no independent anchor separately from low similarity or ambiguous identity. Temporal correspondence may describe or constrain a candidate, but cannot replace the fingerprint test.

Measure raw and capacity-safe local labels, candidate publication labels, and explicit alias snapshots separately. Report per-owner and per-placement coverage, first appearances after eight arrivals, returns, unknown-voice false matches, sample availability, and saturated windows. Ownership annotations include internal pauses and do not establish diarization error rate.

# Isolated installation and validation

`install_bootstrap_embeddings.py` accepts only the exact adapter and collector produced by `install_bootstrap_context.py` from the current production baseline. It writes backups and source hashes, preserving the installed capacity counter and evidence policy. Use an idle isolated checkout; rebuild before inference. The installer never changes the app checkout or runs a model.

The copied replay accepts `GDAY_REPLAY_BOOTSTRAP_SECONDS=45|12` and `GDAY_REPLAY_BOOTSTRAP_EMBEDDINGS=0|1`. Invalid values fail before replay. All four cells use the same instrumented binary; receipt configuration distinguishes them. Defaults are 45 seconds and extraction off.

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/live-speaker-capacity/install_bootstrap_embeddings.py --package-path "$ISOLATED_PACKAGE"
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/live-speaker-capacity/test_bootstrap_embeddings.py
```

Run `test_bootstrap_embedding_evaluate.py` for causal matching and cell-integrity checks. The evaluator accepts only development samples, requires stable model/source/binary provenance, and verifies the requested cell against receipt, trace, and embedding document.

Python checks validate exact installation and unchanged publication, normal sampling, history retention, and rearm policy. Added Swift checks exercise two-second crop selection, capacity and handoff bounds, and separate collector provenance. A 45-second synthetic ramp also verifies the shorter replay origin, restored negative history offset, append/prune coordinates, exact selected PCM, and the next 45-second suffix. They must pass in the rebuilt experimental bundle before model replay. Development outcomes must be recorded before any new validation policy is frozen. Do not read or score the validation cohort during this comparison.

# Technical debt and limits

This is an isolated experiment, not a production feature or a second shipped adapter. The source patch is accepted only to test a bounded mechanism against the existing model. Promote a single reviewed API if the method passes; otherwise retain the measured rejection. Replay awaits extraction and does not reproduce the live controller's busy-sample drops or concurrent transcription. The live controller currently offers People review suggestions and does not automatically name speakers. Production scheduling, manual-correction projection, and cancellation need separate integration and release validation.
