---
title: Remaining changes and repository hygiene
date: 2026-10-16
status: complete
scope: repository-validation
---

## Problem

Completed work remained uncommitted across the macOS app, experiment tooling, and design documents. Private experiment outputs needed consistent ignore rules before committing the full working tree.

## Implemented solution

The root `.gitignore` now excludes every experiment's `.local` directory and Python bytecode. Existing rules continue to exclude private inputs, downloaded models, generated artifacts, run receipts, build products, and temporary validation checkouts. Source, synthetic tests, aggregate reports, and dependency metadata remain eligible for version control.

Three agents reviewed the remaining macOS and experiment changes. The review fixed malformed clip identifiers and timing values in the contextual-audio experiment; its dedicated worklog records the change. The data graph design remains a pending proposal and does not authorize a storage migration.

Full-suite validation also restored throttling for legacy text-only progress updates while retaining immediate publication of explicit structured phase changes. A regression test verifies that a new phase clears pending old messages. The timestamp-gutter fixture now compares its label with the serialized timestamp: stored tenths can round across an hour boundary before display formatting.

## Reasoning

Repository-wide output rules protect newly added experiments without hiding source or synthetic fixtures. Related app changes share persistence and presentation paths, so they are committed together after integrated validation. Experiment tooling and the pending design are separate commits.

## Technical debt

No new debt from repository hygiene. Existing limitations remain documented in the individual worklogs, including manual processing-pipeline recovery after metadata recovery, notes image-operation retries after concurrent edits, and a timing-sensitive transcript scrollbar test fixture.

## Validation

All 38 synthetic experiment tests passed. Candidate Python files parsed, JavaScript and shell syntax checks passed, and all candidate Markdown documents have YAML front matter. Review found no private input files, model downloads, raw provider responses, or credentials among commit candidates. `git check-ignore` confirmed representative private, generated, temporary, and bytecode paths are excluded.

The initial full macOS run completed 1,369 tests in 249 suites and exposed the two issues described above. After the fixes, all 1,370 tests across 249 suites passed. The final isolated `make build-macos` release build passed in 299.39 seconds; source and test bytes match the reviewed checkout. Formatting, lint, and whitespace checks passed. Two existing Command Line Tools linker warnings remain for missing `Developer/usr/lib` and `Developer/Library/Frameworks` paths. No source deprecation warnings were emitted. Validate with a complete Xcode toolchain when available; no warning is suppressed. Existing feature worklogs contain the before-and-after UI evidence; this review does not change UI layout or claim new live capture, provider, or accuracy validation.
