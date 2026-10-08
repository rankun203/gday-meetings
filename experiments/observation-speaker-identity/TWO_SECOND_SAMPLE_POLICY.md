# Two-second clean-speech sampling experiment

Preregistered 2026-10-08, before fresh replay outcomes. This is a development experiment, not an accepted production change.

The existing sampler waits for three uninterrupted seconds of clean single-speaker evidence. Public short-turn development recordings provide embeddings for only three of twelve source owners under the original capacity policy. The embedding extractor already accepts two through ten seconds and centers features using only real input frames. We will lower only the sampler's minimum continuous clean duration from three to two seconds.

Keep the original `nemotron-capacity-rollover-v1` policy, activity model and hysteresis, clean posterior requirement (one channel at least .7; all others below .2), five-second minimum spacing, six-second buffer guard, embedding model/type, and v6 observation identity policy. Do not join discontinuous snippets or relax purity. Do not sweep thresholds or tune against validation. The decision is motivated by the extractor's existing supported minimum and missing short-turn observations.

Freshly infer all four existing public development recordings, then replay their actual callback order through the actual app adapter. Bind the frozen sources, compiled binary, model assets, input audio, output evidence/availability, and publications with receipts. Compare both published and settled identities against the original three-second v1 local-channel baseline, as well as the new frontend's local labels. Report embeddings, owner coverage, identity coverage, confusion, merge precision, split recall, capacity events, and callback resource cost. Source placement ownership is not speech ground truth or DER.

The five private human-reviewed recordings and saved RunPod disagreement remain separate regression checks. Do not infer the disjoint public validation cohort until a complete candidate is frozen from development outcomes. A failure here should diagnose sample quality, boundary support, and local continuity assumptions before changing voice thresholds.
