---
title: Recognition feedback and task strip placement
date: 2026-10-24
status: implemented
---

## Problem

Manual speaker assignment attempts to prepare recognition evidence, but the interface does not explain whether that attempt added a usable voice sample. The task status strip sits below playback and moves playback controls when it appears.

## User Intention

Show recognition status immediately to the left of the assigned person's name, on the same speaker row. Use short text for transient work and compact icons with hover explanations for lasting results. Keep transcript assignment distinct from adding recognition evidence and report the actual outcome. Keep verified recognition outcomes visible while relevant background validation runs, and avoid refreshing unrelated speakers when one reference check completes. Move the task strip above the player so it can appear upward while the player stays anchored. Implement the two changes through separate subagents and deliver another isolated test app, preserving trial decisions and running builds.

## Design

The supplied screenshots establish the existing speaker row and bottom task strip. Preserve the speaker label and assignment menu. Add truthful recognition feedback inside the same row, before the person menu, with accessible meanings and actionable recovery where available. Keep automatic bounded reference selection, and guard against stale outcomes after reassignment, cancellation, failure, or changed audio. A missing historical outcome must not imply successful enrollment.

Place the task strip directly above playback or the active recording transport. Its insertion grows upward and reduces the content area without moving playback controls. Preserve task navigation, attention handling, narrow-window usability, and Reduce Motion.

## Implemented solution

Separate subagents implemented recognition lifecycle/row presentation and task-strip layout/presentation. A third subagent independently reviewed both scopes. The primary agent owns integration, validation, and Test14 packaging.

Recognition outcomes and assignment generations are stored on the existing speaker decision. The worker records whether a sample was added, already available, deferred pending a scan, unavailable, unsuitable, redundant, conflicting, or failed. Current profile membership distinguishes usable recognition evidence from a merely stored sample. Unknown historical outcomes stay neutral. Same-row Checking/Waiting text changes to an outcome icon; hover and accessibility describe its meaning. Clicking opens details with explicit recheck and Voice Samples review. Recheck is bound to the captured assignment decision; user assignment and recognition evidence remain independently authoritative.

LibraryBottomDock places task status before the player/recording transport. A clipped bottom-edge move and fade expands the strip upward; Reduce Motion disables the animation. Running and attention states share a compact native full-row button, preserving active/attention navigation and explicit Review Task text.

## Reasoning

Status must derive from durable recognition evidence and explicit preparation outcomes, rather than generic task completion or a saved person association. The transport should remain a stable target while background work starts and finishes.

## Technical debt

None. Optional outcome fields preserve older decisions without inventing historical success; no outcome backfill is required.

## Notes

Baseline is 027db65 plus the existing sample-name and assignment-keyboard fixes. Concurrent changes to CommunityDiarization.swift, OperationProgressTests.swift, and preparation batching/tests belong to another session and are preserved but excluded from the isolated Test14 source snapshot. The overlapping preparation file is assembled from the baseline plus reviewed recognition changes; independent review verified every other byte matches the baseline.

Independent review found and resolved partial-track gating, recognition usability after playback audio loss, stale same-person retries, cancelled validation errors, and unrelated Undo restoring stale pending receipts (including legacy decisions). Success icons now open information rather than silently retry. The stored-sample explanation was corrected to avoid claiming other samples are selected. No behavioral blockers remain in review.

All 132 targeted tests in 11 suites passed, including ten new recognition lifecycle tests and the hosted dock geometry test. Both release builds passed; the final rebuild adds only the reviewed eight-point status/name grouping. Formatting and diff checks passed. Existing Command Line Tools linker warnings for missing Developer/usr/lib and Developer/Library/Frameworks remain; no new deprecation warnings appeared. Dock geometry coverage checks settled positions; intermediate animation remains a native inspection item. The test uses a transaction that disables animations because Reduce Motion is a read-only environment key on SDK 27.

Native checks verified the task strip above playback, attention navigation, attention-to-running transition with the same playback position, historical unknown outcomes, assignment-to-scan-needed feedback, explicit recheck, and opening Voice Samples from the details popover. A temporary synthetic fixture supplies typed voice records because the older general preview uses unknown legacy vectors. The first screenshot exposed a flexible menu-width gap; the final row groups status and name at eight-point spacing while retaining the long-name cap. The final release screenshot verified adjacent status/name controls and long-name truncation in both normal and native half-screen windows. The scan-needed outcome persisted across restart.


Test14 was packaged, signature-verified, and launched as `027db65-test14-0a45c0ca`, using an isolated copy of the latest 20 completed meetings and 2,992 voice examples from Test13. Source files stayed unchanged during shared-lock capture; independent baseline files were retained. Running-process open files verified the Test14 library, with remote providers and automatic processing disabled. Older apps and libraries are preserved. Source manifests, the exact source archive, preparation scripts, validation logs, and builds remain in ignored `tmp/review-test14/`.

Validation limits: intermediate animation frames, the system Reduce Motion setting, and active-recording transport were reviewed in code but not exercised natively. Dock tests verify settled insertion/removal/height-change/no-player geometry. Recognition success/failure/stale-retry/Undo/restoration paths are automated; native checks exercised historical and scan-needed outcomes. Source remains uncommitted alongside preserved concurrent work; no push or CI run was requested.


Test15 follow-up: testing exposed broad badge invalidation. A library-wide revision and the full people array restarted every successful badge validation; clearing usage first replaced completed outcomes with ellipses. The accepted design scopes dependencies to the affected reference/profile and retains verified state during same-assignment refresh while rejecting stale responses and invalidating changed assignments or removed evidence. Implemented with cached effective per-person profile generations, target sample/representation dependencies, and a validation-state reducer. Unconfirmed and representation-only updates reuse cached conflict grouping. Same-sample refresh keeps verified usage; failure retains the icon with an explicit last-verified explanation. Changed sample/model/assignment eligibility invalidates the affected outcome, stale completions are rejected, and shared-query cancellation retries are bounded. Six focused regression cases passed in the integrated run (86 tests across nine suites, including popup, native transcript, passage assignment, and reference-selection coverage). Independent review verified the scoped Store against the Test14 archive and found no remaining blockers; the final release build, formatting, diff checks, packaging, and signature verification passed. Native verification is limited as described below. The user authorized a new isolated app after collecting feedback; Test14 remains running and its latest completed-meeting state has been captured consistently.


Test15 delivery: `027db65-test15-3faa058d` is packaged at ignored `tmp/review-test15/Gday Meetings Scan Test15.app`. A refreshed, shared-lock/hash-verified capture retains the latest 20 completed Test14 meetings and 2,995 examples, with an independent baseline and remote/automatic processing disabled. The prior trial remains untouched. Runtime file checks verify the Test15 library, bundle revision, exact executable hash, and signature. Source manifests and a full validated source/test archive are retained under the same ignored directory.

Test15 native limit: computer use repeatedly returned `cgWindowNotFound` for both Test15 and Finder, so changed-screen screenshots and manual interaction checks could not be completed. Process sampling showed the app normally idle in the AppKit event loop; no startup hang was observed. The 86-test result includes state/dependency and grouped-context regressions; it is not a claim of native interaction verification. Existing Command Line Tools linker-path warnings remain. No commit/push was requested; concurrent changes are preserved and excluded from this build.
