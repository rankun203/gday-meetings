---
title: Expand local meeting sample review
date: 2026-10-01
status: completed
scope: reference-only-review-preparation
---

# Problem

Preparing independent listening clips required a local model output even when the reviewer could begin annotation before inference. More local meeting samples were needed to broaden the review set.

# Implemented solution

`build_review.py` now accepts a saved-reference-only set. Without model outputs, the caller must request zero disagreement-selected diagnostic clips. Random selection, hashes, blind annotations, and scoring retain their existing format. Tests verify deterministic sampling, genuine reference provenance, export, scoring, and command-line validation without invented predictions.

The follow-up adds optional targeted speaker coverage. For each saved label, the builder centers a clip on its longest interval and deduplicates identical windows. The private key records the `speaker_coverage` category and its proxy-label limitation. Random selection remains unchanged, and the exporter excludes targeted clips from independent scores. Additional local meeting samples were prepared; saved labels guide coverage but do not establish how many people are audible.

Preparation selected four additional local meeting samples and ten random 20-second clips from each. The 40 new clips were added as new sample directories without changing existing active review annotations or restarting the review server. Separately, the requested annotation resets retained backups and kept the original local audio and clips. Additional local meeting samples cover more languages and recording environments.

# Reasoning

Random clip sampling does not need model predictions. Allowing the saved reference alone lets annotation proceed independently while keeping unavailable comparisons absent. Disagreement diagnostics require another system and are rejected in this mode.

# Technical debt

The initial additional sets contained only the saved reference. The follow-up evaluation completed full-track inference for every selected reviewed sample and linked verified predictions to frozen annotations through a private evaluator. The generic review exporter still has no automated prediction-attachment workflow, so reproducing this expanded comparison depends on the private evaluation receipts and script. Add a generic receipt-validated attachment command before repeating this workflow with new samples.

# Validation

Fourteen review tests passed, including reference-only and targeted-coverage cases. Seven review-server tests and six gold-scoring tests passed. All 40 initial additional WAV hashes and 20-second durations were verified against their review keys. The subsequent 41 clips passed the same checks and cover all 7, 5, and 13 saved labels on their respective tracks. Every added clip starts unreviewed, and no local-model output was fabricated. No UI or Swift code changed.

# Completed evaluation

The follow-up scored 97 reviewed clips from eight local meeting samples, keeping 66 random clips separate from targeted and diagnostic clips. All local inference runs completed. Independent validation passed 156 score views, 56 original-export comparisons, 13 derived-annotation checks, and 12 pooled arithmetic checks. A reviewer-confirmed identity correction was applied through the revision-safe API and a recorded evaluation overlay; frozen originals remain unchanged. Aggregate results are in `experiments/diarization-benchmark/RESULTS.md`. The complete 97-clip dataset and reproducible notebook remain local under ignored `tmp/`.

The evaluation report also includes model payload, architecture, CPU and memory counters, setup dependencies, and integration requirements. The added resource audit reads existing verified receipts; it does not rerun inference or change model configuration. Latest and historical batches remain separate, and absent server measurements remain explicitly unknown.
