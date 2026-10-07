---
title: Opus preparation for speaker labeling
date: 2026-10-07
status: complete
scope: macos-audio
---

# Opus preparation for speaker labeling

## Problem

Speaker labeling failed during temporary audio preparation with an error that placed the final duration outside the final decoded packet. The service-input conversion used a separate Core Audio decoder and required end trimming to fit within the last packet. A synthetic Ogg fixture reproduces the rejected timing structure without using private recording data.

## Implemented solution

`AudioPlaybackPreparation` uses the existing `OpusFileDecoder` for temporary CAF conversion and duration metadata. libopusfile handles pre-skip, header gain, and end trimming. Conversion preserves mono or stereo channels, uses bounded buffers, checks cancellation, and verifies the output frame count. The existing container scan still rejects checksum errors, truncation, interrupted streams, chaining, and trailing bytes. Temporary-file cleanup remains owned by the existing preparation and consumer paths.

Tests compare prepared samples with playback for independent synthetic fixtures with varied packet durations and mono/stereo audio. A fixture with trimming across several packets on the final page checks conversion and metadata duration.

## Reasoning

Reuse the pinned decoder already used for playback rather than patching the parallel decoder's timing assumptions. RFC 7845 section 4.4 defines retained samples over the final page; its last-packet trimming limit is a recommendation rather than a validity requirement. The separate validation pass preserves strict damaged-file rejection at the cost of an additional sequential scan.

Reference: [RFC 7845](https://www.rfc-editor.org/rfc/rfc7845.txt), sections 4.4–4.5.

## Technical debt

None. Container validation remains separate from sample decoding to preserve existing corruption checks.

## Validation

Formatting, lint, and whitespace checks passed. The initial focused run passed 24 tests in three suites. The final run passed 33 tests in eight suites, including Opus playback, preparation, encoding, resampling, metadata consumers, and a ten-hour bounded-memory playback fixture. The final test command explicitly loaded the installed Swift Testing macro plugin, as the repository test script does, after an incremental run encountered the documented plugin-discovery failure.

An isolated `make build-macos` release build succeeded with macOS 26.0 minimum and SDK 27.0; plist and code-signature checks passed. A final build after synchronizing the source snapshot also passed (87.79 seconds). Source and test snapshots match the working tree. The first sandboxed test attempt could not launch Swift's compiler sandbox. An initial isolated build rejected copied compiler caches tied to their original path; those isolated caches were removed before retrying. Copied build-state cleanup reported stale paths outside the isolated root. Command Line Tools linker search-path warnings and the existing Core Audio non-interleaved-file diagnostic remain; no deprecation warnings were reported. These toolchain diagnostics did not prevent passing tests or release validation.

No UI code changed. The running app and private recordings were not replaced or modified. The affected real recording and provider labeling job have not been rerun. Remote CI results are checked and reported separately after pushing.
