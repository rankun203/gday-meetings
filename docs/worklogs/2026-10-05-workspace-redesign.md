---
title: Workspace redesign and continuous lists
date: 2026-10-05
status: implemented-with-validation-limits
scope: macos-library-directory-tasks
---

## Problem

The previous refresh changed surfaces without sufficiently changing the workspace layout. The supplied Voice Memos reference demonstrates clear navigation, list, and detail columns, scoped toolbar groups, restrained list rows, and a distinct playback area. Our preview has a floating sidebar, a headerless meeting list, crowded detail controls, and People and Tags detail sections constrained to short manually paged lists. Tasks replay and publish the complete history, sort it during view updates, and synchronize progress writes on the main actor.

## Design and work plan

Baseline screenshots are in `tmp/workspace-redesign-2026-10-05/before/`. They use synthetic content. The user reference informs geometry and hierarchy only; its recording content is not used in fixtures.

1. Establish shared column geometry and ownership before parallel screen changes. Use an integrated navigation column, a distinct list column with a persistent heading and scoped actions, and an opaque detail workspace. Keep search accessible and preserve playback across destinations. Remove duplicated global actions and misleading empty states.
2. Redesign meeting details with a compact title and metadata header, secondary actions, intrinsic content tabs, and more vertical room for the selected content. Keep transport controls distinct and accessible at the minimum window size. The baseline player occupies one large glass card with a decorative icon tile; use a quiet waveform surface and a compact glass transport capsule, preserving broad scrubbing and 44-point transport targets.
3. Redesign People and Tags as directory workspaces. Use consistent selectable rows, contextual editing, and a substantial automatically paged associated-meetings area. Preserve selection when a row leaves a loaded page.
4. Implement cursor-based People and Tags presentation and storage queries without treating unloaded records as deletions. Preserve per-record conflict checks and authoritative files. Preserve the existing bounded, bidirectional Meetings pager.
5. Separate active task execution from paged task history. Keep the journal authoritative, use a disposable offset index, and avoid repeated whole-history replay and sorting. Preserve durable recovery boundaries and task identity. Present a chronological task list with selected details and scoped actions.
6. Integrate the parallel changes, inspect the complete diff, and validate each affected screen at regular and minimum sizes. Check forward and reverse scrolling, selection, search, task recovery, and light and dark appearances. Save before/after comparisons in the new temporary folder, validate a release build in an isolated checkout, commit, push, and check the macOS CI matrix.

## Ownership

- Primary agent: shared shell, toolbar, list headers, integration, native visual validation, release and delivery.
- Directory agent: directory persistence and paging, People and Tags lists, relevant tests and consumer migrations.
- Task agent: task history indexing and paging, task workspace, recovery and performance tests.
- Detail agent: meeting content hierarchy and People and Tags detail layouts, associated-meeting continuous scrolling.

Shared initialization and shell changes are coordinated through explicit integration hooks. Agents do not overwrite one another's files or run competing builds in the isolated checkout.

## Implemented solution

The shared shell now uses native split navigation, scoped list creation actions, destination-specific empty states, and a quiet playback surface with a glass transport capsule. Meeting details use a compact identity header and a Details popover. People and Tags have indexed directory rows and larger associated-meeting workspaces with automatic bidirectional loading.

The first rebuilt native capture exposed a build-level cause of the old system appearance. Swift Build compiled object files against SDK 27.0 but stamped the final executable with SDK 14.2. An isolated package reproduced this; `--sdk` and `SDKROOT` alone did not correct it. The documented linker `-platform_version` option now explicitly supplies the app's existing minimum from its bundle metadata and the selected SDK version. Release packaging checks both values with `vtool`. No executable patching or minimum-version increase is used. Rebuilt native captures confirmed the current system control appearance.

Directory lists retain at most 400 compact indexed rows. Associated meeting lists retain at most 200 rows and preserve the visible anchor across page rotation and index refresh. Tasks use 50-row cursor pages with a 150-row presentation window, a 100-record nonrunning cache, and separately retained running operations. Progress updates no longer append or synchronize journal events. The chronological task list replaces repeated full-width cards with selected-task details and All, Active, Needs Attention, and History scopes.

Integration review corrected exact-tag lookup, explicit directory selection reveal after adding or merging, empty refresh windows after records move before the cursor, indexed task payload validation, and recovery of orphaned running tasks after an external journal change. Minimum-width capture found that the nested split view could retain its wider list allocation and clip both outer edges. The list width now follows the space allocated by native navigation. Rebuilt captures passed at 900-point width for meeting details, Notes, People, Tags, and Tasks, with working native divider resizing. A subsequent minimum-list-width check found that action labels displaced the heading; header menus now use accessible icons and tooltips, and prioritize the heading.

## Reasoning

Changing materials alone does not address the hierarchy shown in the reference. List virtualization alone also does not address full-history task replay or synchronous progress writes. Layout and storage changes are therefore separate workstreams with shared integration checks.

## Technical debt

Directory editing, merging, and existing picker consumers retain complete canonical People and Tags snapshots. The directory views use indexed cursor pages, but startup and those consumers remain proportional to total directory size. Retaining the canonical catalogs avoids treating unloaded records as deletions in the existing transactional save path. Future work should migrate those consumers and transactions to explicit per-record hydration and mutations before removing the catalogs.

The directory projection still scans source entity files on startup. Name filtering, exact-name lookup, and counts may scan the indexed names, and corrupt derived databases remain quarantined for diagnosis. These choices preserve correctness with bounded returned payloads, but do not make every query constant-time. Follow-up work should add durable freshness tracking, indexed normalized lookup and count caching where measurements justify them, and a quarantine retention policy.

Voice preparation retains its separate fully hydrated job catalog. Task history presentation pages those rows with journal-backed tasks; replacing voice persistence requires a separate migration of its scheduler and review consumers. Rare durable task transitions still synchronize the journal on the main actor; only frequent progress updates are transient. Moving durable transitions off-main requires ordered, acknowledged persistence. The authoritative journal has no compaction, so first indexing remains proportional to event history; introduce crash-safe compaction separately. Speaker-labeling history reads at most 500 task records off-main and reports that limit; a paged history browser is the follow-up. Ephemeral background jobs remain separate from persisted history because they have no durable identity or recovery contract.

Explicit linker platform versions compensate for Swift Build's incorrect final SDK metadata on the current toolchain. This is supported build configuration and reads both versions from their existing sources. Retain the post-link assertion; once upstream linking is corrected and the CI matrix proves the default values, the explicit flags can be removed. The existing Command Line Tools search-path warnings correspond to [SwiftPM issue 10557](https://github.com/swiftlang/swift-package-manager/issues/10557); a toolchain update is the follow-up, rather than suppressing the warnings.

The broad parallel test run retains timing contention across shared MainActor/AppKit fixtures. Serial execution validates the full suite but does not eliminate this harness limitation or establish production behavior under contention. Follow-up work should gate streamed fixture chunks on acknowledgements instead of relying on a transient draft remaining visible for fixed delays, and isolate AppKit integration tests in a shared serial process. Production timeouts were not increased and the normal test command was not changed to hide these failures.

## Validation

Before captures cover Meetings, People, person details, Tags, and both empty and populated Tasks. Integration tests initially found task scheduling/recovery regressions and timing failures. Correctness fixes passed focused reruns and the final full serial suite: 852 tests in 145 suites, 94.755 seconds. Directory paging tests include 1,200-entry forward/reverse traversal with a bounded window. Formatting, lint, and diff checks passed.

After display access returned, native captures confirmed the new SDK-linked control appearance. Synthetic interaction checks covered Meetings, Notes editor and reader, Summary, meeting privacy, People, Tags, Tasks, Agents, search, and General, Service Providers, Data, and Data Privacy settings. People and Tags scrolled beyond 400 retained rows and returned to the beginning. Associated meetings passed 200 retained rows and returned; Tasks reached completed task 240 and returned without losing selected details. Meetings reached the end of the 325-meeting fixture. Search returned three source-specific matches. Native sidebar collapse and expansion worked. Dark and minimum-width capture exposed the column sizing issue described above.

Two debug diagnostic runs used 100,000 journal events representing 10,000 tasks. The first measured legacy opening at 2.286 seconds, new cold indexing at 3.322 seconds, and reopening the persisted index at 0.000852 seconds. One hundred 50-row first-page queries took 6.832 seconds with the old implementation and 0.214 seconds with the index. The second run was comparable. Cold indexing is slower; warm reuse and bounded history queries improve. These are storage diagnostics, not release UI frame-time measurements. Source, logs, and results are under `tmp/workspace-redesign-2026-10-05/benchmark/`.

Broad parallel tests exposed timing contention in asynchronous suites. The sidebar test also assumed that SwiftUI animation completion completed native split-view feedback. It now requires stable resulting state, while preserving the immediate rapid-reversal check. Its focused reruns and final full serial run passed. The production build and Preview packaging passed in the isolated `/private/tmp/gday-glass-refresh` checkout, including signing and linked SDK 27.0/minimum macOS 14.2 checks. The final header-only follow-up passed another release build and native capture at a 250-point list width; the Meetings heading and Add Meeting control remain visible. The verified production bundle is available at `tmp/workspace-redesign-2026-10-05/production/Gday Meetings.app`. Post-push macOS CI status is reported with delivery.

Existing Command Line Tools linker warnings name missing Developer framework/library search directories; no API deprecation warning has been observed. Comparison captures and a local HTML index are under `tmp/workspace-redesign-2026-10-05/comparisons/`. Fixtures were expanded between captures, so counts differ.

Validation limits: the preview uses synthetic silent audio, synthetic providers, and synthetic task states. It does not establish real-device recording, provider processing, or end-to-end playback performance. The original proposal's 30-second frame/hitch traces at 1,000 and 10,000 meetings, 10,000-segment transcript, full VoiceOver/Full Keyboard Access and accessibility-preference matrix, and macOS 14.2 runtime check remain unmeasured. Storage timing and bounded paging tests do not substitute for those measurements. Existing older-platform material fallbacks remain availability-gated.
