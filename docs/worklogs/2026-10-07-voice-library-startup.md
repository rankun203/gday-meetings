---
title: Load the voice library after the initial window update
date: 2026-10-07
status: implemented
scope: macos-voice-library-startup
---

## Problem

The startup trace attributed about 494 ms of main-thread CPU to opening the saved voice library. Startup constructed the preparation controller, which synchronously decoded metadata, inspected file revisions, and recovered interrupted jobs. This delayed interaction even before a voice capability was used.

## Implemented solution

The production voice store now starts without reading files. After the first visible window update, the app delegate requests one shared utility-worker load. The worker opens persistence, reads metadata and job state, and durably pauses interrupted running or queued jobs before returning a complete document. The main actor adopts the backend only after its worker has finished; concurrent callers share the same load and cannot write an empty startup snapshot. Cancelling a caller does not cancel shared recovery.

Voice actions await readiness. Normal meeting navigation can load without waiting for voice metadata; it preserves saved associations while opening, and startup completion reconciles loaded meetings with the saved decisions. Transcript adoption, recovery, meeting deletion, and labeling wait for loading to finish but remain available when voice storage fails. Actual voice writes still require readable storage, and person mutations report its failure. Live voice recording awaits readiness within the existing cancellable processing task, with recording and cancellation checks before saving a sample. A live assignment accepted before Stop can finish after readiness; request tokens preserve the latest assignment for each meeting and speaker. The library-folder control stays disabled until opening finishes.

Embeddings remain unloaded until a selected sample or association operation requires them. Startup no longer constructs the preparation controller. The local extractor and discoverer already initialize models inside extraction or discovery; opening metadata does not acquire a model or contact a provider. Tests and synthetic previews explicitly select immediate loading when their fixtures require synchronous seeding.

## Reasoning

Moving only a main-actor task into an asynchronous closure would still block the interface during filesystem work. The utility worker owns the persistence backend exclusively during loading and recovery, then transfers ownership to the main actor. Existing storage locking, transaction recovery, and canonical-save admission remain intact. This keeps startup loading separate from processing while preserving saved jobs.

The startup callback uses [AppKit's application update notification](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdidupdate(_:)) after a visible window has updated. This is a window-update boundary; it does not prove that the compositor has presented the first frame. An explicit voice action can request readiness sooner.

## Technical debt

Existing synchronous on-demand embedding hydration and post-readiness voice commits remain on the main actor. This change does not redesign those operations, which have separate transaction and identity-review requirements. They can still affect responsiveness when a voice feature is used. Profile those interactions separately, then move storage operations to a serialized worker with coherent snapshot publication if they are significant. Publishing and indexing metadata also remain on the main actor; a very large metadata set may require preparing those projections on the loading worker.

The existing voice and task views show empty lists while metadata opens; loading indicators require a separately designed UI change. Automatic startup loading requires a visible user-facing window, while explicit voice actions can start it independently. Validate restoration with no visible window before adding another lifecycle trigger; an arbitrary timer would weaken the requested window-update boundary. Immediate synthetic Preview recovery can run twice and remains idempotent.

## Review

Claude Code's default model was verified as `claude-opus-5-5[1m]` in its initialization events and `claude-opus-5-5` in the assistant response metadata. Its read-only review found a high-severity regression: failed readiness prevented independent transcript and labeling workflows, meeting deletion, and failure diagnostics. A synthetic corrupt-metadata adoption test reproduced the failure. Separating completion from readability fixes those paths without permitting voice writes, and added tests cover failed startup recovery, runtime refresh failure, deletion, and read-only job recovery. The reviewer also found a narrow live-assignment loss around Stop; capturing eligibility before the wait and admitting only the latest request repairs it. The blocked-worker cancellation test now confirms its second caller has entered the wait before cancellation.

The reviewer confirmed exclusive worker ownership, one shared load, jobs-only recovery, and protection against empty-snapshot writes. Two follow-up reviews, also verified as `claude-opus-5-5[1m]`, found no remaining high- or medium-severity issue. They identified low-severity ordering details: later saved assignments now invalidate older live requests, transcript adoption flushes preceding canonical writes before finalizing converted samples, and a replaced queued enrollment returns success as a no-op so it cannot abort a later flush. Storage unavailability retains its own diagnostic, separate from incidental playback errors. Held-worker and held-write regressions cover these paths; the final startup suite passed 10 tests, and the assignment suite passed 11 tests. A final isolated confirmation also passed all 10 startup tests plus the previously failing cross-page merge case. The reviewed repairs passed a new isolated release build and packaging validation. UI loading feedback, windowless startup, duplicate Preview recovery, intermittent broader-suite failures, and post-change Instruments measurements remain validation limits.

## Validation

Added startup tests for a blocked storage worker with an available main actor, shared and cancelled readiness callers, interrupted-job checkpoint recovery without decoding embeddings, and failed loading without writes. The affected voice persistence, preparation, association, task recovery, source-label recovery, and transcript adoption suites passed 85 tests together; the person merge suite passed 6 tests separately. Broader runs also produced intermittent person merge and assignment failures, including cross-page person merge assertions in a run with parallel testing disabled. These have not been fully attributed. A scoped HEAD baseline replaced the voice/startup implementation and its fixture changes in the isolated checkout while retaining unrelated pre-existing source changes: the cross-page merge case passed there, while the provider-list expectation failure reproduced. That expectation assumes two configured providers while normalization adds This Mac, so it predates the voice optimization.

The final readiness-observation change passed 9 startup and task recovery tests. `make format-macos` and `git diff --check` passed. The final source passed `make build-macos` in an isolated checkout, including packaging and signature verification, with macOS 26.0 minimum and SDK 27.0. The running development bundle was preserved. The initial isolated build reported stale paths from copied build artifacts; the final build retained Command Line Tools linker warnings about missing Developer library and framework search paths. No new deprecation warning was encountered.

No post-change Instruments trace has been recorded. The 494 ms figure describes the original capture, not a measured improvement. No view layout or controls changed.
