---
title: Search loading progress
date: 2026-10-07
status: complete
scope: macos-search
---

## Problem

The search field showed a repeating accent gradient during index and model preparation. It communicated activity without advancing toward completion.

## Implemented solution

Keep the native search field and its two-point bottom-edge indicator. Fade in one accent-colored fill, advance using the last successful preparation duration, finish on actual success, then fade out. Hold estimated progress at 95% when preparation exceeds the estimate. Failure or cancellation fades the current fill without indicating completion. Reduce Motion uses discrete progress updates without animation.

Store optional key/value measurements in the independently versioned `core_runtime` module's `runtime_observations` table in `index.db`. The key includes the search model's embedding space; the value is the last successful preparation duration in seconds. Missing, invalid, or inaccessible observations fall back to one second. Failed and cancelled preparations do not replace observations.

## Reasoning

Preparation exposes stage changes but no measured completion fraction. Elapsed time against a previous successful duration gives estimated progress; it cannot guarantee an exact completion time. Retain actual loader completion as the authority. The database is disposable, so observations require no authoritative source file or migration of existing library records.

## Technical debt

None. Duration estimates are a deliberate measurement model, not measured work completion. Cold starts, cache changes, and system load can change duration.

## Notes

Inspected the user-supplied loading screenshot and captured the running app's idle search field before editing. Preserve its native placement, text editing, keyboard focus, and layout. The production app was left running. Validation uses an isolated checkout under `/tmp/gday-search-validation` and synthetic Preview loading via `--synthetic-search-loading`; this fixture performs no inference or observation writes.

Validation passed: `make format-macos`, `make lint-macos`, `git diff --check`, the focused `RuntimeObservationsTests` persistence/model-isolation/invalid-sample test, and `make build-macos` in the isolated checkout. `make build-macos-preview` rebuilt the final source and packaged it successfully. The release binary declares macOS 26.0 minimum and SDK 27.0.

Captured final Preview in light and dark appearance, including partial fill, near-full fill, and the idle field after completion. Typed a synthetic query during loading and verified Tab navigation. The native field retained its size and focus behavior. Command-F reached the existing missing-model setup alert in this fixture; dismissing it restored the focused field. No model download or inference was started. Reduce Motion, resize behavior, real model durations, and failure/cancellation appearance were reviewed in code but not exercised live. Individual 180 ms/200 ms fade timing was not measured frame by frame.

Screenshot provenance: isolated bundle `/tmp/gday-search-validation/apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`, built October 7, 2026; `GdaySyntheticSearchLoading=true`; synthetic library; macOS 26.6.2; Swift 6.4; SDK 27.0. Final search-field source SHA-1: `469314788abc52e3ee7bce6b284e83fceaef65f6`. Captures were inspected through computer-use tooling and were not committed.

Build warnings: the installed Command Line Tools linker reports missing search paths under `Developer/Library/Frameworks` and `Developer/usr/lib`. These are toolchain search-path warnings, not deprecated APIs; compilation, linking, platform validation, and signing succeeded. No deprecation warning was emitted in these checks. Follow-up if the warnings persist after a Command Line Tools update: inspect SwiftPM's generated linker flags and report the missing paths upstream. No warning suppression was added.

Existing unrelated untracked files were preserved. No commit, push, or installation was requested; CI was not triggered. The running production bundle and library were left untouched.
