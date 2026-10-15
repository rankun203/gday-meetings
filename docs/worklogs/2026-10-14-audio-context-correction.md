---
title: Audio context correction experiment
date: 2026-10-14
status: complete
---

# Problem

Determine whether reviewing short bilingual audio clips with vocabulary and an existing transcript can correct recognition errors.

# Implemented solution

Added a bounded, reproducible API experiment in `experiments/audio-context-correction/`. Five clips were evaluated with two prompt conditions. A primary run used a broad roster with the current audio model; earlier selective-vocabulary diagnostics used two models. Private inputs and generated outputs remain ignored. Production code and meeting-library files were not changed.

# Reasoning

Compare independent contextual transcription with bounded revision to expose anchoring on existing errors. Include two unmarked controls and preserve unusable responses. An older audio snapshot was used only in initial diagnostics. The primary realistic run uses the current model and keeps expected corrections out of the request.

# Technical debt

None. This is a standalone experiment, not a production correction service. Empty-output handling, human ground truth, and confidence-based selection remain unimplemented product requirements rather than deployed shortcuts.

# Notes

Thirty HTTP 200 responses and one failed request were retained across all rounds. In the realistic roster run, one of three target categories was fully recovered in both conditions. Controls showed wording drift and unusable responses. The results report explains the limited ground truth, usage, latency, and lack of verified cost. The script was executed successfully; its help output and private-file ignore rules were checked. No Swift files changed, so a macOS build was not required.
