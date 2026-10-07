---
title: Bootstrap context observation
date: 2026-10-08
status: experimental
scope: live-speaker-capacity-experiment
---

# Purpose

Observe how a new Nemotron window labels the replayed audio that the old window already labeled. The same audio can supply temporal correspondence between distinct local identities without inheriting a channel number or consulting reference owners. This first stage measures available context; it does not implement voice fingerprint association or change app names.

# Isolated instrumentation

`install_bootstrap_context.py` changes only a copied `LocalLiveDiarization.swift` and its copied replay collector. It requires exact production adapter and collector bytes, rejects paths that resolve outside the isolated package, preserves both original files, and writes before/after hashes. The capacity implementation and evidence policy are read and hash-recorded without modification. The copied capacity counter can therefore remain the separately installed experimental v2 counter.

Do not install while a model replay or build uses that checkout. Keep its previous source and binary receipts. After installation, rebuild before running; never pair the modified source with an earlier test binary.

```sh
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python experiments/live-speaker-capacity/install_bootstrap_context.py --package-path "$ISOLATED_PACKAGE"
UV_CACHE_DIR=tmp/uv-cache uv run --no-project python -m unittest discover -s experiments/live-speaker-capacity -p 'test_*.py'
```

# Trace schema

The copied collector writes availability schema version **2**, with `contextPolicyRevision` equal to `bootstrap-context-v1-experiment`. The clock remains `submitted-audio-upper-bound`. Context shares the ordered callback stream with published speaker events and completed embeddings, so every entry has one `ordinal` and `audioSubmittedThrough` value.

A context entry has `kind: "bootstrapContext"` and a `bootstrapContext` object:

| Field | Meaning |
| --- | --- |
| `source`, `generation`, `speakers` | New local namespace and identity metadata |
| `start`, `end`, `intervals` | Observed context chunk and its active local identity intervals |
| `contextOrigin` | Start of the replayed audio in recording time |
| `handoff` | Single publication timestamp between old and new windows |
| `capacityReachedAt` | First capacity timestamp known when this callback is emitted; omitted while unknown |
| `policyRevision` | Capacity policy used by the copied adapter, separate from the context trace revision |

Context bounds are clipped to `[contextOrigin, handoff)`. Empty-activity chunks remain observable when their time range is nonempty. A model result crossing the handoff produces context before the handoff and the unchanged published event at or after it. Buffered context emitted after bootstrap processing also follows this rule; the probe does not rely on the temporary `replaying` flag.

# Publication invariants and interpretation

The context callback never appends to evidence activity, samples, or trusted windows. The original publication clipping and voice sample selection remain unchanged. It adds no bootstrap embedding extraction. Existing old-window output owns all pre-handoff speech; new-window publication starts at the same timestamp as before instrumentation.

Future correspondence evaluation must use only callbacks already received, keep source identities separate, and clip old and new context to their respective capacity cutoffs. Do not name post-handoff speech merely because temporal overlap produced a match. A saturated bootstrap can provide context but zero trusted continuation after handoff; report that case explicitly.

The replay submits bounded audio blocks and awaits extraction. Callback order is measured, but submitted audio time is only an upper bound on audio availability within the block. No wall-clock latency, busy-skip behavior, reference identity, or future activity may be substituted for observed evidence.

# Validation and technical debt

Installer tests check exact backups and hash receipts, reject modified or escaped destinations, and verify that sample selection, publication clipping, and the published collector remain textually unchanged. The copied Swift suite adds a crossing-boundary test that checks separate context/publication intervals and confirms context does not enter evidence. That Swift test must pass in the rebuilt experimental bundle before replay.

This guarded source patch is a reproducibility mechanism for an isolated observation experiment. It is not a shipped adapter fork. If the mechanism demonstrates a useful, validated policy, implement one reviewed production API and preserve this experiment as an immutable comparator. Otherwise retain the negative result without adding a production feature flag.

# Frozen correspondence probe

`bootstrap_associate.py` evaluates temporal correspondence on development inputs only. At the first positive-duration publication, it compares already received bootstrap activity with already published activity from the same source. Both sides are clipped to their known capacity limits. Empty generation announcements do not trigger decisions.

A new label needs at least three seconds of exclusive agreement with one prior identity, at least 80% agreement over its exclusive context, and a margin of at least 20% over the next candidate. Known overlapping new labels cannot share an identity. These fixed engineering criteria were recorded before outcomes; they are not calibrated voice-matching thresholds. A bootstrap already at capacity admits no aliases. Context never supplies extra scored activity.

The probe reports labels available at publication separately from the final alias snapshot. It verifies that both preserve the original published speaker-seconds, and binds the input cohort, sources, binary, model assets, and scoring implementation. Structural checks reject inconsistent namespaces, timing, and policy metadata. Validation inputs are not accepted by this development probe.

The isolated Swift bundle passed ten focused tests across capacity and replay suites, including context/publication clipping and evidence separation. The opt-in model test was skipped in this unit run and is executed separately by the replay driver. Existing Command Line Tools linker search-path warnings remain unchanged.
