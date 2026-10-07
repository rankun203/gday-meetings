---
title: Shared transcript height measurements
date: 2026-10-07
status: implemented
scope: swift-macos-transcript-performance
---

# Shared transcript height measurements

## Problem

Each meeting page created its own height cache. The table delegate synchronously measured text and retained transcript strings in that cache. Returning to a meeting repeated the work. Width settling also performed a full reload and forced synchronous layout after source updates.

## Implemented solution

`LibraryView` owns an in-memory `TranscriptLayoutService`, passed through the environment to saved and live transcript views. Each meeting still creates a fresh native table and coordinator. The service retains compact measurement keys and heights; it owns no table, cell, editor, or playback state.

Keys include meeting and row identity, a content fingerprint computed when constructing the row, device-pixel-normalized text width, typography version, and layout version. Rendering uses the same normalized text width. The initial typography/layout versions describe the existing fixed system font, text-field insets, row padding, and fixed speaker-column geometry. Future changes to these inputs must update their version. Speaker names are truncated in a fixed column, so renaming a speaker does not change height.

A missing height returns an estimate immediately. The coordinator requests visible rows followed by eight nearby rows on each side. A single utility worker measures immutable strings with the same NSString metrics and system font used before this change. Results publish in batches of at most 16. The main actor applies only changed row heights and preserves the top visible row ID and offset. During initial review-link or playback positioning, it retains the explicit target row’s offset until the viewport is measured. User interaction clears this temporary navigation anchor. Corrections cancel obsolete follow animation and wait while the scroller is being dragged. Stale keys cannot update the current table. Page changes cancel obsolete work cooperatively; the service tracks the existing worker until it exits, preventing rapid navigation from creating concurrent measurement workers.

The cache starts with a 16 MiB estimated budget, three variants per row, linked least-recently-used eviction, bounded visible protection, and memory-pressure cleanup. The queue normally holds at most 128 inputs and 1 MiB of input text. Live updates rebuild keys only for the changed tail. Saved views supply authoritative row IDs so hidden audio tracks retain cached heights, while deleted rows remove cached/pending entries and cancel affected in-flight work. Moving a meeting to Trash from the library or an associated-meeting list removes its cache entries. Width settling notifies row-height changes without a duplicate full reload or forced synchronous layout. Existing targeted source updates and isolated playback highlights remain.

## Reasoning

A window-owned service preserves warm measurements while keeping selection, editing, and playback isolated in each page. The synchronous delegate performs only a dictionary lookup. Secondary indexes and linked eviction avoid scanning or sorting the whole cache during ordinary lookup, insertion, or publication. The library presents one active transcript page at a time; its service has one active measurement owner. Independent transcript presentations outside the library receive their own fallback service.

Apple's [thread-safety guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html) permits NSString drawing metrics on workers and restricts view operations to the main thread. Worker-local font/input values avoid sharing mutable layout objects. Independent native text-field tests check wrapped text, multilingual text, explicit breaks, tabs, and narrow widths, including the existing two-point safety allowance.

## Validation

Before editing, inspected the existing isolated synthetic Preview transcript in Dark appearance. The intended layout and controls are unchanged: timestamps, speaker badges, wrapped text, editing, and playback highlights. The before bundle was `tmp/recording-menu-validation/apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`, labeled `recording-menu-dirty`; it establishes interaction/layout evidence, not current-source performance.

Focused validation passes 44 tests across native transcript, live native transcript, native geometry, and layout-service suites (1.526 seconds, after compilation). The final strengthened canceled-seek assertion also passes independently. A synthetic 10,000-row fixture performed zero text measurements from all row-height callbacks, measured 19 cold viewport rows, and performed zero additional measurements when a fresh table reopened that viewport. Its peak pending work was 15 inputs / 2,805 estimated bytes; cache bookkeeping was 12,160 estimated bytes. These counts establish bounded viewport work and warm reuse, rather than installed-app timing improvements.

Final production source passed the isolated `make build-macos` path through `make build-macos-preview` (102.88 seconds). Canonical `make format-macos` and `git diff --check` passed. The linker still reports missing Command Line Tools search paths ending in `Developer/usr/lib` and `Developer/Library/Frameworks`; these existing toolchain warnings require checking the installed toolchain configuration rather than changing transcript APIs. No deprecated API was introduced.

The rebuilt Preview was `tmp/transcript-layout-validation/apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`, revision label `4508d86`, built `2026-10-07 07:38 UTC`, with the current uncommitted Swift source copied into its isolated checkout. Enabled its synthetic 10,000-row fixture in the Preview-only property list. Captured and inspected Dark and Light screenshots, returned through a different meeting page, scrolled to later rows, edited and saved a wrapped line, and resized the sidebar/transcript split. Timestamps, speaker badges, wrapping, and controls matched the intended unchanged design; the edited and resized viewport retained its top row. User recordings and the installed development bundle were untouched.

The [transcript layout journey](../../Tests/UserJourneys/transcript-layout.md) defines cold/warm navigation, long transcripts, rapid selection, resizing, edits, live appends, playback, memory pressure, and profiler checks. No installed-app CPU/stall improvement is claimed before a comparable Instruments run. `xctrace list templates` did not list Time Profiler or Hangs in this environment, including with the full Xcode developer directory selected; no synthetic trace was recorded. Allocations and real recording/live append interaction measurements remain pending. An earlier broad test run also encountered unrelated store/voice timing failures; the focused suites above establish this change's correctness and do not imply the complete suite passed.

The service emits worker intervals named `Transcript measurement batch` and main-thread intervals named `Transcript height publication` through OSSignposter, following [Apple’s current documentation](https://developer.apple.com/documentation/os/OSSignposter). The `transcript-layout` unified-log category reports aggregate cache, measurement, cancellation, and peak pending-input counters when a page deactivates. These diagnostics include no meeting identifiers or transcript text.

A read-only Claude Code review used the configured default Claude Opus 5.5 model; stream initialization identified `claude-opus-5-5[1m]` and review messages identified `claude-opus-5-5`. The first review found width/partial-update invalidation, estimate flicker, deferred edit publication, cancellation retry, owner handback, live-update complexity, filtered-row invalidation, navigation/follow correction, memory estimates, duplicate identity handling, deletion paths, and stale comments/test gaps. Those findings were evaluated and addressed. Follow-up reviews found width-only bookkeeping and canceled-follow anchor lifetime issues; these were corrected and covered by native geometry and paused-seek regressions. Anchor release now checks the current viewport after publication and applied heights, and an expired offscreen anchor falls back to the top visible row. The final targeted review found no remaining correctness issue and suggested checking that the regression actually creates an anchor; that additional assertion passes.

## Technical debt

The 640-byte entry cost is an estimated bookkeeping budget, not a verified Swift allocation size. Validate and tune it with Allocations; additional dictionary/index storage is not an exact allocation accounting mechanism.

One input larger than the normal 1 MiB queue allowance runs alone rather than truncating valid transcript text. It retains the existing Swift string value, not a second stored transcript cache. An individual measurement can exceed that allowance and cancellation occurs between rows. If measured large-row behavior warrants it, replace this exception with incremental paragraph measurement that preserves native wrapping and metrics.

Measurements currently cover the viewport and its nearby margin, rather than proactively measuring every offscreen row. This limits navigation work, but scrollbar geometry may continue to settle while scrolling. Verify row-ID anchoring and large transcript behavior in the journey; add bounded idle batches only if measurements show they improve the experience.
