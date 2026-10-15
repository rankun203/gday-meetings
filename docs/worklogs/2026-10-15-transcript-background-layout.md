---
title: Background transcript layout preparation
date: 2026-10-15
status: ready-for-user-validation
scope: macos-transcript
---

# Background transcript layout preparation

## Problem

Unmeasured transcript rows use estimated heights. On first scrolling and after a width change, short rows briefly have excess space and long rows can clip until background measurements arrive. The fixed eight-row margin can leave upcoming rows unprepared.

## Implemented solution

`NativeTranscriptView` requests visible rows first, then up to two viewport heights ahead and one behind. Requests contain at most 128 rows, ordered nearest first in the scroll direction. Width and source changes reset direction tracking. The existing utility worker, byte budget, cache keys, and cancellation rules remain in place.

Worker completion notifications use the existing main-queue measurement scheduler, which combines pending notifications before applying cached heights. This is not display-frame throttling. Navigation anchors settle based on visible rows, without waiting for the larger margin. Row-height callbacks still only read cached values or estimates; no text measurement moved to the main thread.

## Reasoning

The supplied before/after screenshots establish the visual target: retain the timestamp, speaker, and text columns and existing controls while reducing transient spacing corrections. No loading gate or synchronous text measurement was added. Larger bounded prefetch trades some background work for earlier preparation; it cannot guarantee exact geometry after an arbitrary scroll jump.

## Technical debt

Estimated offscreen heights remain an intentional latency tradeoff. Cold views, rapid jumps, and new widths can still require visible corrections. Measure correction frequency and main-thread layout cost before considering additional warming. No new schema, compatibility bridge, or duplicate scheduling mechanism was introduced.

## Validation

The isolated checkout contains only this task's changes on the existing committed source. The targeted run passed 53 tests across native transcript, live transcript, geometry, layout service, and viewport ordering suites; the opt-in performance probe was skipped. The new integration test verifies automatic background publication without a manual flush, native row-height agreement, prefetch beyond the former eight-row margin, bounded work, and a stable top offset. Existing tests cover nonzero anchors, resize, revision changes, editing, and duplicate row identities.

A synthetic 10,000-row fixture performed zero text measurements in row-height callbacks, measured 32 rows for the cold viewport and margin, and required zero additional measurements to reopen the warm viewport. Peak pending work was 21 inputs and 3,927 estimated bytes; cache bookkeeping was 20,480 estimated bytes. These are work counts, not evidence of lower frame latency or better perceived smoothness.

Formatting and lint passed in the isolated checkout. Independent implementation and test review found no blocking issue; the completion comment was corrected to avoid implying display-frame throttling. `make build-macos` passed in the isolated checkout, including packaging and signature verification, with macOS 26.0 minimum and SDK 27.0. Test and release linking emitted missing Command Line Tools search-path warnings for `Developer/Library/Frameworks` and `Developer/usr/lib`; no deprecation warning was observed. The warnings are retained as an environment limitation; inspect the selected toolchain's injected linker paths before changing package settings. No remote CI run was requested because this task commits locally without pushing.

Computer-use capture failed on initial and final attempts with `Sky Computer Use native pipe startup failed`. Initial visual evidence is the user-supplied screenshots. Changed-screen capture and manual interaction validation remain pending; automated geometry checks do not establish perceived scrolling smoothness.

The isolated Preview build and signature verification passed. Its bundle at `/tmp/gday-transcript-layout-validation/apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app` has `GdaySyntheticLongTranscript` enabled, equivalent to `--synthetic-long-transcript`. For the final visual check, open Synthetic conversation and check the first scroll, both scroll directions, a large jump, and scrolling after resizing. Confirm readable wrapping, stable reading position, editing, and playback highlighting. No real library data or recording is needed for this check.
