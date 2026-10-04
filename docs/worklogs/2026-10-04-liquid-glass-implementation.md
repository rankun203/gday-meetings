---
title: Liquid Glass implementation
date: 2026-10-04
updated: 2026-10-05
status: implemented-with-validation-gaps
scope: swift-app-ui
---

# Liquid Glass implementation

## Problem

The October 3 appearance audit identified heavy navigation and transport chrome, inconsistent spacing across screens, and a toolbar search that replaces the meeting list while typing. The app-wide theme needs production adoption. The subsequent keyboard-focus fix is already present and must be preserved.

## Plan and design groundwork

1. Preserve the clean `ae018e5` baseline in an isolated release Preview. Inspect the existing audit captures and fresh screen states before editing each family.
2. Establish shared semantic spacing, quiet reading surfaces, and one availability-checked native chrome modifier. Keep macOS 14.2 support and opaque accessibility fallbacks.
3. Assign parallel ownership: library/sidebar and indexed Search Results; meeting/detail/player and recording; settings/provider screens. The integrating agent owns People, Tags, Tasks, Agents, shared primitives, and Preview provenance.
4. Integrate without replacing native tables or document engines. Resolve overlapping layout contracts, then rebuild an isolated Preview and inspect every primary screen and provider family.
5. Save before/after comparisons and validation logs under ignored `tmp/liquid-glass-refresh-2026-10-04-v2/`. Run formatting, relevant tests, release validation, and inspect the complete diff before committing and pushing. Check the macOS CI matrix afterwards.

The inspected baseline has broad gray content regions, a toolbar search, edge-attached transport, and dense but strongly selected meeting rows. The target retains the three-column workflow: inset rounded sidebar with top search; opaque lists and documents; compact content actions; a single wide inset player with tracks above transport. Directory and settings screens retain native lists/forms, with shared section spacing and readable status rows. Native dialogs and menus retain platform presentation. Glass is reserved for stationary navigation and persistent controls.

## Implemented solution

- `AppTheme`, `AppChromeSurface`, and `AppContentSurface` establish shared spacing, opaque reading surfaces, and native glass on macOS 26 with regular-material and accessibility fallbacks. Native controls retain their own sizing and interaction.
- Library navigation uses an inset sidebar with Return-submitted search. The dedicated native results table preserves draft/submitted queries, selection and viewport, pages indexed passages, opens the matching content without playback, and provides Back to Search Results. Derived index version 3 stores stable passage locations; existing authoritative meeting files are unchanged. Excluded tags apply before counting and paging. Saves queue passage refresh through the existing background reconciliation worker.
- The player is one inset rounded surface with expanded tracks above transport. Wide layouts expose speed and track controls; narrow layouts use an options menu. Playback ownership and 44-point transport targets remain unchanged. Meeting content, recording, directory, task, voice-review, agent, and settings screens use the shared surface and spacing contracts.
- General/provider settings use wrapping status text with symbols, grouped capability explanations, and native forms. Data settings give folder paths a separate selectable row. Recording retains prominent red start/stop actions.
- Fixed timestamped Markdown list layout: the timestamp prefix now advances the list tab stop, so bullet and task text remains visible in both text engines. Added a geometry regression test.
- Preview shows build revision/time, exposes a gallery of production components, and supports documented synthetic providers, live recording, tasks, pagination, and 1,000/10,000-meeting fixtures. Large-library file generation runs off the main actor. Added fixture tests and an opt-in native scrolling measurement harness.

## Reasoning

Shared visual policy preceded parallel migration so screen owners composed the same materials and metrics. Integration preserved native table reuse, document identity, and playback ownership. The sidebar keeps the system list's selection appearance, including its accent selection when active; changing that through private introspection would add fragile code. Search uses individual passages rather than matching phrases across unrelated documents. The storage change replaces the disposable aggregate search index instead of maintaining duplicate indexes.

The first visual pass exposed raw Markdown search excerpts and an overly eager compact player layout. Excerpts now reuse the production Markdown parsers. An explicit width threshold replaces the unsuitable ideal-size fit for player options. Independent review also found and fixed missing excluded-tag filtering in the new results query.

## Technical debt

- No new custom-control simulation, authoritative schema migration, duplicate search index, or private API was introduced. Native-material compatibility is required by the macOS 14.2 minimum and can be removed only when that minimum changes.
- Retained layout limitation: person details use the existing outer vertical stack. Source review identifies a risk that short windows with long notes, many voice samples, or errors may squeeze the question area. Normal captured dimensions pass; a follow-up should reproduce the minimum-height case and, if needed, give the profile section bounded scrolling without nesting the chat scroll area incorrectly.
- Validation debt is listed below. Do not treat source review, release compilation, callback timings, or earlier-build screenshots as proof of all runtime acceptance targets.

## Validation

Baseline revision: `ae018e5`. Isolated build path: `/private/tmp/gday-glass-refresh`. Fourteen first-refresh comparison entries, capture provenance, logs, and performance artifacts are under ignored `tmp/liquid-glass-refresh-2026-10-04-v2/`. The existing development app and real library were not changed.

- Release builds: baseline Preview 210.91 seconds; first refresh 144.66 seconds; corrected Preview 210.64 seconds; final source `make build-macos` 161.27 seconds. Bundle validation and signing passed. Runtime: macOS 26.6.2, arm64; Swift 6.4 and SDK 27.0. No API deprecation diagnostics. The local Command Line Tools linker still warns about missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths; use the installed Xcode toolchain for a clean environment check rather than suppressing these warnings.
- Formatting and lint passed. Final suite results and the diagnosis of the first run’s failures are recorded below.
- Inspected first-refresh captures: transcript, Notes editor/reader, People, voice review/preparation/assignment, General top/bottom, This Mac provider, Data, search results/result opening/empty state. The reader now visibly renders timestamped bullet/task text. Settings status text and paths wrap without clipping at the captured dimensions.
- Exercised Return search, draft/submitted separation, empty submission, no matches, keyboard result activation, transcript positioning without playback, Back restoring selection, and collapsed-sidebar Command-F. Playback selection stayed intact across navigation. Pointer tab selection preserved the earlier focus fix.
- The display session locked after the second Preview build (`CGSSessionScreenIsLocked=Yes`), blocking UI capture: computer-use returned `cgWindowNotFound` for Preview, Finder, and Chrome, including after reconnecting. The Preview process was alive and idle in its normal event loop. Final player/sidebar corrections and remaining provider, task, recording, narrow, dark, keyboard, and accessibility states still need capture after the user unlocks the display. Earlier screenshots are explicitly labeled; they are not final-build validation.
- Reduce Transparency, Increase Contrast, Full Keyboard Access, VoiceOver, inactive appearance, minimum-width layout, macOS 14.2, and older runtimes are not yet a completed runtime matrix. Source-level availability checks preserve the declared deployment target.
- The performance harness records callback intervals, layout/draw cost, CPU, and physical footprint with conserved work. It does not measure compositor-presented frames or real audio playback. Installed Instruments templates do not expose Animation Hitches or Time Profiler; frame-budget and end-to-end playback targets remain unproven.

### Final isolated release tests · October 5

Built the unchanged baseline plus the scrolling harness in `/private/tmp/gday-glass-perf-baseline` (331.08 seconds), archived its test bundle, then synchronized the final source and rebuilt release tests (186.13 seconds). Both builds retain the documented Command Line Tools linker search-path warnings; no API deprecation diagnostics were reported.

The complete final release suite passed **830 tests in 142 suites in 70.978 seconds**, run serially with normal filesystem-event access. This includes the timestamped-list regression and all nine search tests. The earlier failures were reproduced as parallel timing contention, a missing isolated migration script, and sandbox-blocked filesystem events; targeted reruns passed without weakening assertions or extending test deadlines. Logs and the final bundle hash are in `tmp/liquid-glass-refresh-2026-10-04-v2/performance/final-suite/`.

### Native scrolling diagnostics · October 5

Ran two fresh processes per revision with the same release configuration, 1,200 × 800-point native test window, and identical harness. Each process covered 1,000 and 10,000 meeting/transcript rows in idle, silent playback-progress, and synthetic live-update modes. All **24 cases completed 43,200 scroll/layout operations**, preserving **14,400 playback updates and 480 live updates**. Each case delivered 1,800 scheduled operations over at least 30 seconds; delayed operations were completed rather than dropped. No builds or interactive UI checks ran during the measured workloads. The display remained locked, so window presentation was unverified.

Ranges below show the two runs. “Layout” measures the synchronous scroll, update, layout, and draw request; callback intervals and process CPU also include work between these requests. Neither timing is a compositor-presented frame measurement.

| Rows | Mode | Baseline p95 layout, ms | After p95 layout, ms | Baseline CPU, s | After CPU, s | Baseline / after callback gaps over 100 ms |
| --- | --- | --- | --- | --- | --- | --- |
| 1,000 | Idle | 5.39–5.43 | 5.47–5.50 | 27.74–27.94 | 28.21–28.33 | 0 / 0 |
| 1,000 | Live updates | 5.53–5.61 | 5.56–5.63 | 22.75–23.32 | 23.44–23.71 | 0 / 0 |
| 1,000 | Playback updates | 5.57–5.71 | 5.66–5.67 | 28.55–28.69 | 28.67–28.68 | 0 / 0 |
| 10,000 | Idle | 18.64–20.64 | 18.24–20.28 | 30.21–31.54 | 30.08–30.68 | 1 / 2 |
| 10,000 | Live updates | 18.18–18.20 | 18.13–19.84 | 30.26–30.30 | 30.05–30.82 | 3 / 1 |
| 10,000 | Playback updates | 18.00–20.05 | 18.21–18.98 | 30.17–31.68 | 30.22–30.43 | 2 / 1 |

The worst callback interval was **133.06 ms before and 123.04 ms after**; the worst synchronous action was **43.55 ms before and 45.86 ms after**. No synchronous action exceeded 100 ms, but six baseline and four after callback gaps did. Aggregate timings cannot locate their cause: deferred SwiftUI/AppKit work, scheduling, and native test-host behavior remain possible contributors. The action proxy excludes deferred work after the call returns, so its smaller maxima do not dismiss those gaps. The small upward shifts in the 1,000-row idle/live CPU ranges and mixed 10,000-row results are diagnostic observations, not proof of a source regression or a no-regression pass. Two repeats do not provide the three-repeat scaling lane or a statistical confidence interval.

Memory did not establish settled retention. During the 10,000-row idle cases, sampled physical footprint grew from **66.7 to 1,242.3 MiB** and **68.4 to 1,169.3 MiB** before; after, it grew from **68.2 to 1,036.2 MiB** and **69.9 to 1,037.3 MiB**. Later cases reclaimed differing amounts. These are test-process measurements with no post-work settling window, under a locked display and a test host that finishes application launch without entering the normal app run loop. They do not prove a production leak or bounded retention.

**Performance acceptance remains unresolved.** This harness exercises production native tables directly, with all fixture rows supplied. It does not cover index paging, full-shell glass composition, real audio, provider inference, presented-frame hitch rates, or settled memory across repeated application navigation. Confirm the long-library and retained-memory behavior in the unlocked production Preview with a causal UI/render trace before claiming the refresh meets those targets. The installed Xcode and Command Line Tools template inventories both lacked Time Profiler and Animation Hitches; `xctrace list instruments` returned no instruments. No causal frame trace was collected.

Artifacts are under `tmp/liquid-glass-refresh-2026-10-04-v2/performance/`: successful baseline runs `baseline-run2`/`baseline-run3`, after runs `after-run1`/`after-run2`, `comparison.json`, full resource logs, and runner manifests. `baseline-run1` failed before loading tests because the selected Command Line Tools lacked the Testing framework; it contains no measurements and is excluded. The runner then used the installed Xcode test helper/framework for both revisions. Test-bundle SHA-256 values: baseline `49de173588043346b02aa35e98dc734e844db7ca5dc292a3052ec482eb8dc4ef`; after `05882d25b84d4499bd9cf8a0b63007e1669faf1a9804a545f9bc75ba9a103ea8`.
