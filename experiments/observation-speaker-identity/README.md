---
title: Historical observation speaker identity evaluation
status: archived after removal of live diarization
scope: retained results and independent audio review utilities
---

# Historical evaluation

The user replaced the experimental live observation pipeline with post-recording Speaker Diarization. Its live runtime, retained-evidence consolidation engines and dependent experiment runners/tests have been removed. Historical results and policy documents remain evidence of measured successes, failures and the decision; they are not instructions for the current production pipeline.

[RESULTS.md](RESULTS.md) preserves the frozen comparisons, including the unresolved fragmentation regression. Historical source/binary/model/input receipts and private audio remain in ignored `tmp/`. Do not mistake those results for validation of the replacement post-recording pipeline.

Three independent utilities remain useful without the removed Swift APIs:

- `prepare_user_sources.py` prepares source-hashed full PCM inputs from explicitly authorized meeting directories, without editing originals.
- `make_review_shortlist.py` creates playable review clips from saved acoustic-output JSON, including deterministic random controls and optional bound provider disagreements. Clips are not human truth labels.
- `audit_capture_timing.py` correlates a saved journal with recorded PCM loudness and a recorded inference trace. It can investigate past capture problems but cannot establish AGC causation.

Use each script's `--help` for arguments. Their outputs belong under ignored private `tmp/`; no recording is uploaded. The current architecture and product behavior are documented in the new post-recording diarization worklog, not these archived experiments.
