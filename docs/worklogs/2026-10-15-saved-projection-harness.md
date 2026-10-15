---
title: Validate projection with copied analysis artifacts
date: 2026-10-15
status: validated
scope: macos-diarization-validation
---

## Problem

Comparing alignment and speaker projection requires identical transcript and acoustic inputs. Rerunning inference or changing a library would confound that comparison.

## Implemented solution

Added `SavedDiarizationProjectionHarnessTests`, enabled only by `GDAY_SAVED_PROJECTION=1`. It reads copied source and acoustic artifacts from environment paths, projects them in memory, and writes `projected.jsonl` and text-free aggregate `metrics.json` only under temporary or `.local` storage. It verifies exact original text reconstruction, contiguous source-anchor coverage, timed-span content and timestamp conservation, and unchanged input files before writing results.

## Reasoning

The harness exercises the production assignment entry point without audio inference or library access. Run the same copied artifacts against each code revision with separate output directories; input hashes identify equivalent runs. Attribution coverage is not an accuracy measure.

## Technical debt

None.

## Validation

The opt-in harness passed against copied artifacts in 0.327 seconds, as part of 53 passing release tests. It preserved every source character and all 11,690 timed spans, with 10,176 attributed spans versus 10,162 in the saved prior projection using identical acoustic turns. Projection itself took 0.143 seconds. These are coverage measurements, not accuracy scores. An initial Swift Testing macro compile error was corrected by reading throwing file operations before the assertion. Formatting and diff checks passed. Ordinary test runs leave the harness disabled.
