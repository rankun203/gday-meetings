---
title: Keep People matching responsive
date: 2026-10-08
status: validated
scope: macos-voice-matching
---

# Problem

The release benchmark measured a 3.010-second main-actor stall while building matching profiles from 8,000 confirmed examples. Faster conflict detection alone did not address representation reads and profile selection.

# Implemented solution

`VoiceMatchingWorker` owns a separate read-only persistence backend on a serial actor. It loads the required confirmed and rejection examples, selects up to twelve representations per model and person, and computes suggestions away from the main actor. Persistence validates each consumed representation and the library revision before returning. The store verifies current reviewed metadata and revision before using results.

`matchingPeople` is asynchronous and throwing. `suggestReviewedPeople` awaits the same worker and discards cancelled or stale results without clearing valid suggestions. Identical requests share a task; cancellation removes a caller's subscription and cancels work when no callers remain. Profile-only and suggestion requests have separate slots on the serial worker, so one mode cannot cancel valid callers of the other. A superseding snapshot cancels obsolete tasks. Record reads hold only short shared locks, and selection holds no filesystem lock.

Call sites await matching. Live sample recording checks recording identity, source audio, and the example quota, then persists an unassigned example before requesting suggestions. Profile preparation and rejection checks both run on the worker. An unavailable match preserves the captured embedding and existing suggestions. Recorded labeling refreshes suggestions after saving its meeting update, avoiding a new suspension between constructing and publishing transcript changes.

# Reasoning

An independently owned reader avoids concurrent use of the writable main-actor backend. Snapshot and file-revision validation preserve manual clears, reassignments, deletions, and external representation changes. Serial worker execution bounds simultaneous hydration. A permanent cache would need additional invalidation and storage rules; this implementation retains no completed profile cache.

# Validation

Worker tests cover main-actor availability, review changes during matching, cancelled suggestion preservation, representation and metadata replacement after hydration, coalesced caller cancellation, concurrent request modes, and live evidence retention when suggestions become stale. Integration cases check both live suggestions and reviewed-rejection vetoes. An independent review identified cross-mode cancellation; separate operation slots fix it. The live path now persists first to avoid synchronous rejection hydration after profile preparation.

The final full app suite passed **1,164 tests in 202 suites in 112.502 seconds**, including the live suggestion and rejection cases. A sandboxed attempt could not use native log, file-event, layout, audio, and Trash services; the final run used normal platform access. The isolated checkout initially omitted the repository migration script; copying it fixed that fixture failure. An intermediate slower run reported two automatic-summary timeouts; those tests passed unchanged both alone and in the final full run. No timeout or assertion was weakened.

The isolated `make build-macos` release build passed in **260.92 seconds**, including macOS 26.0 minimum / SDK 27.0 checks, plist validation, and signature verification. The existing Command Line Tools warnings for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths remain; no deprecation warning appeared. These paths come from the installed toolchain; no warning suppression or deployment-target workaround was added.

The release benchmark passed with 8,000 confirmed 256-dimensional vectors across eight people: **6.206232 seconds** total matching, **514 main-actor heartbeats**, and **58.725 ms** maximum observed heartbeat gap on a 10 ms schedule. Every person received twelve samples. The baseline call occupied the main actor for 3.009986 seconds. Total time increased; additional revision checks contribute I/O, without a separate timing ablation. This measurement verifies actor availability during profile preparation, not rendered frame rate or bulk metadata-write latency.

Source hashes, binary hashes, aggregate metrics, and log paths are saved in ignored `tmp/async-voice-validation-20261008.json`. Final logs are `/private/tmp/gday-async-voice-all-tests-complete.log`, `/private/tmp/gday-async-voice-release.log`, and `/private/tmp/gday-async-voice-profile-release.log`.

# Technical debt

None added. Full-library profile construction still has proportional read and selection costs; these run on the worker and retain all evidence. Live recording no longer enters the synchronous rejection-hydration path. Existing review persistence remains unchanged. No schema change, compatibility shim, or evidence cap was introduced.
