---
title: Collect a deployed worker comparison outside the library
date: 2026-10-15
status: complete
scope: experiment-client
---

## Problem

The saved remote transcription had diarization disabled. The deployed worker cannot return raw turns or skip recognition, and updating its deployment would delay comparison.

## Implemented solution

Added an isolated client under `experiments/runpod-output-comparison`. Preparation copies metadata-selected audio and verifies hashes. Separate submit and poll commands use the existing Filedrop and RunPod APIs, preserve private state and full output, and never adopt results into the library. Credentials are read without migration and never logged. Submission intent is durable before the non-idempotent POST; ambiguous outcomes cannot be automatically resubmitted.

## Reasoning

A full remote job is necessary with the deployed API. Keeping it outside the app preserves saved transcripts while allowing a final-output attribution comparison. Raw acoustic comparison remains unavailable from this response shape. No worker deployment changes remain.

## Technical debt

The experimental client mirrors a small subset of the app's provider transports. This is accepted to avoid coupling validation to library persistence. It can drift as provider contracts evolve; retire it after the comparison or update it alongside those contracts before future use. Interrupted uploads require manual inspection rather than automatic recovery, avoiding duplicate transfers and submissions.

## Validation

The primary agent executed one authorized isolated job after reviewing the client. Copied audio hashes matched the originals before and after copying; no library result was adopted. The remote response was retained privately and reported 366.179 seconds execution plus 13.431 seconds queue delay. All 17,251 returned words had speaker labels. The 19 synthetic client, comparison, and review tests passed.

Final aligned-label agreement was 98.19% for the microphone and 91.51% for system audio, conditional on mutually single-speaker intervals after label mapping. Local unresolved timed intervals remain substantial, and the remote fill-nearest policy prevents interpreting its complete assignment as accuracy. The results document separates these denominators, before/after projection changes, resource limits, and proposed local tuning. Production model defaults were not changed. `git diff --check` passed.
