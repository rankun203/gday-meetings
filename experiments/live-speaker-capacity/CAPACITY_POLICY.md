---
title: Capacity establishment candidate
date: 2026-10-08
status: preregistered
scope: live-speaker-capacity-experiment
---

# Problem

The production policy requires three continuous seconds on every channel. Development replay exposed eight channels with at least three seconds of cumulative activity long before that condition held. In the arrivals schedule, cumulative activity reached that point at 62.8 seconds, while the current capacity timestamp was 141.1 seconds. In short turns, cumulative evidence reached it at 34.36 seconds, but the current policy did not roll over during the 99.6-second recording. These are development observations, not validation outcomes or proof that all eight channels represent different people.

# Frozen candidate

The experimental replacement uses revision `nemotron-capacity-credible-runs-300ms-total3s-v2-experiment`. A channel becomes established after three seconds of accumulated activity from runs lasting at least 300 ms each. The first 300 ms of a qualifying run receive credit once the run reaches that duration. Subsequent active frames add their own duration. Shorter runs receive no credit, and silence never adds evidence. Established channels remain sticky until the window resets.

This proposal was stated before candidate replay outcomes. The 300 ms screen is a fixed engineering choice, three times the existing 100 ms activity-off debounce. It rejects brief isolated activity rather than accumulating every model flicker. It is not a calibrated confidence estimate. We did not select it by searching development thresholds, and validation outcomes must not be used to adjust it.

The three-second total, eight-channel capacity, 300 ms silence boundary, five-second maximum wait, 45-second replay horizon, and saturated-bootstrap rearming remain unchanged. This isolates establishment from rollover scheduling and identity association. Pure cumulative activity was rejected as the first candidate because arbitrarily short repeated false activations would eventually establish a channel.

# Execution and provenance

`LiveSpeakerCapacity.swift` is an experimental replacement with the production API. Copy it only into an isolated experimental checkout. That checkout must also change `SpeakerEvidenceWindow.protectedPolicy` to the candidate revision before building. Never produce candidate evidence with the production v1 revision, and never relabel existing evidence as if it came from this policy. Record the candidate source, copied protected-policy source, executable, inputs, and output hashes in replay receipts.

Run the standalone checks from the repository root:

```sh
swiftc experiments/live-speaker-capacity/LiveSpeakerCapacity.swift experiments/live-speaker-capacity/CapacityPolicyChecks.swift -o tmp/live-speaker-capacity-20261008/capacity-policy-checks
tmp/live-speaker-capacity-20261008/capacity-policy-checks
```

The four checks exercise repeated short turns, isolated blips, precise threshold credit, unchanged continuous establishment, sticky counts, reset, saturated bootstrap, and rearming. They require Foundation only and do not load models.

# Evaluation and risks

Compare unchanged production and candidate runs on identical development recordings first. Report capacity timestamps, generations, saturation behavior, known-owner confusion, merge precision, split recall, output coverage, and activity during injected silence. Earlier rollover is not itself success: false channels can trigger unnecessary resets and fragment a person's speech. Evaluate the frozen candidate on the disjoint validation cohort only after the development result warrants it.

Repeated false runs longer than 300 ms can still consume capacity, and fragmented real speech shorter than the screen remains uncounted. Activity hysteresis can join closely spaced bursts into one qualifying run. Bootstrap may establish eight channels sooner and remain saturated longer under the new count. These are explicit evaluation risks, not reasons to claim the candidate is already safe.

# Technical debt

The experiment intentionally duplicates the small capacity implementation to isolate the candidate from production. It is not a production runtime fork. If the policy passes validation, promote one implementation and archive this experimental source as a reproducibility artifact; if it fails, retain its measured rejection without adding a production toggle. No compatibility migration or production schema change is introduced here.
