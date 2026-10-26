---
title: Speaker reference dataset
date: 2026-10-26
status: planned
scope: reference-dataset-construction
---

# Speaker reference dataset

Build a versioned reference from real meeting audio for evaluating Speaker Diarization, cross-meeting Speaker Association, and learning from corrections. Use VibeVoice-ASR on Runpod and a pyannote commercial model as independent annotation proposals, with targeted human adjudication and a separately audited test set.

Start with two or three complete meetings around ten minutes each. Measure cost and resource use, preserve output equivalence while optimizing execution, then expand in measured stages to full recordings copied from the main library. Dataset quality takes precedence over throughput.

Read [PLAN.md](PLAN.md) for the implementation contract and next-agent handoff. [RESULTS.md](RESULTS.md) records measured outcomes; no inference has run for this experiment yet.

## Source and artifact locations

- Tracked: this directory's documentation, future reproducible scripts, schemas, and synthetic tests.
- Private working root: `tmp/speaker-reference-dataset/` (already ignored by the repository).
- Credentials: load only the required Runpod variable from `apps/client-macos-swift/.env` at runtime. Never print values, copy the file to a worker, or include it in artifacts. The file's existence was checked; its contents were not read for this plan.
- pyannote access: the user will prepare the commercial account/key. Implement its adapter and mocked tests while access is pending.
- Existing reviewer: preserve port 8771, its data, and feedback. This is an independent experiment.

## Running

There is no runnable harness yet. The next agent implements the stages in PLAN.md, adds exact CLI instructions here, and records the tested revisions and commands in RESULTS.md. Do not treat proposed command names as implemented software.

Run standalone Python through `uv run --no-project`, with dependencies specified through `--with`; pin the resolved environment in each run receipt for reproduction. Use synthetic fixtures for committed tests.
