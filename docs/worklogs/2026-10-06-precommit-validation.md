---
title: Combined macOS validation before commit
date: 2026-10-06
status: complete
scope: swift-macos-release
---

## Problem

The focused persistence, transcript, and People-search checks passed, but the first full run exposed interactions between file notifications, cold meeting loads, shutdown callbacks, and delayed saves. The user requested a validated commit and push of the combined changes.

## Implemented solution

- Cold meeting loads distinguish superseded snapshots from failed reads. Active consumers retry a file-notification invalidation; cancellation, deletion, and library-generation changes still stop the request. Concurrent consumers continue sharing one current read.
- External task reload and wake callbacks reject admission before joining the serialized command queue once shutdown begins. Recovery rechecks after awaiting preparation.
- Archive import creates its reserved dated directory before yielding to the save queue. Evicting the in-memory path reservation can no longer replace the source date with today's date.
- An asynchronous recording-language save updates the recognizer only if the same recording is still active.
- Three restart fixtures explicitly load cold meetings. The transcript recovery fixture waits for storage outside the simulated provider's real deadline. The archive regression uses a persistent gate flag rather than a consuming semaphore predicate. The queued-summary fixture holds its first response until all tasks are admitted, rather than assuming admission finishes within a fixed delay.

## Reasoning

These changes preserve the asynchronous persistence contracts while addressing failures found under the full suite's concurrent workload. No timeout was increased and no failed assertion was removed. Deterministic tests reproduce snapshot invalidation, late callback admission, and reservation eviction.

## Technical debt

None introduced by these corrections. The broader persistence and name-detection limitations remain documented in their implementation worklogs.

## Validation

The final full run passed all 975 tests across 171 suites in 32.294 seconds with no compiler warnings or errors. Earlier full runs exposed the production races and timing-dependent fixtures described above. Formatting, lint, and staged diff checks passed. The final release build passed in 162.51 seconds without warnings or errors, with macOS 26.0 minimum, SDK 27.0, valid bundle metadata, and strict signature verification. The attribution notice received whitespace-only cleanup during staging; its credits and license text are unchanged. CI results will be checked and reported after the requested push.

The complete source, test, resource, and documentation changes were reviewed across the parent and three existing task agents. Synthetic fixtures and bundled dictionary attribution were checked. The isolated release Preview retry succeeded: exact-name, partial-name, name-plus-topic and content-only search; opening the matched Person; Labelings loading; and transcript width/meeting-switch behavior were inspected and captured. The Preview was quit before final packaging. The installed app is preserved.
