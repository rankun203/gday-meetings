---
title: Transcript scroll work
date: 2026-09-27
status: complete
scope: swift-transcript
---

# Transcript scroll work

## Problem

The saved transcript created a multiline editor for every visible row, scanned the segment array for each editor read, and checked audio files on disk per row. Every keystroke saved the meeting and reloaded transcript history. The first compact SwiftUI revision removed those costs, but the user still reported unsatisfactory scrolling and requested row hover plus a smaller meeting header.

## Design evidence

Captured the existing Synthetic conversation transcript in isolated UI Preview before editing. The user's Rust reference requests compact rows, subdued speaker badges, and no separators. Preserve timestamp, speaker, and wrapped text alignment. Single-click a reading row to play its segment. Double-click text to edit, or a speaker badge to open an anchored person autocomplete. Return or leaving the editor saves; Escape cancels. Keep native text selection while editing and **Copy Text** in the reading row's contextual menu.

The latest Preview screenshot confirms excessive header height from the 44-point play control and padding. Use a 28-point play control, reduce top padding from 24 to 12 points, and tighten header spacing. Add a subtle full-width native hover background. Keep detailed speaker management available in a collapsed **Speakers** disclosure below the viewport.

## Implemented solution

`NativeTranscriptView` uses AppKit's reusable `NSTableView` rows inside an `NSScrollView`, with cached wrapped-text heights and the window's shared field editor. Scrolling does not instantiate SwiftUI row trees, read files, or look up speaker names. `MeetingTranscriptView` caches lightweight row models and presentation flags when transcript or person data changes, and passes a generation token to the native adapter. Playback-only updates do not reload or compare the full row array.

Native single-click playback waits for the system double-click interval; a double click cancels it before editing or opening the speaker picker. Draft text remains local until commit. An active edit commits to its captured meeting/segment before its reusable cell is rebound. Height cache keys include row ID, text, speaker text, and available width. Deleted rows are removed from the cache. Native row tracking areas draw hover without publishing state into SwiftUI. Wheel and momentum events suppress hover until 150 milliseconds of idle time; drawing checks the actual pointer location, so reused rows cannot retain another row's hover state.

The speaker autocomplete returns at most 20 sorted matches and supports creating or removing an assignment through the existing store API. Keyboard Return edits the selected row; native accessibility actions expose text editing and speaker assignment. `MeetingDetailView` uses the compact header and metadata-only playback availability; actual file checks occur when playback starts.

## Reasoning

The first optimization retained SwiftUI's lazy stack to minimize interaction changes. User testing showed that was insufficient. Native row reuse now removes SwiftUI layout work from the scrolling path. Native selectable reading text conflicted with the requested double-click edit gesture, so selection is available in the active editor and the reading row offers **Copy Text**.

## Technical debt

The selected transcript payload and its lightweight row models remain in memory. Initial row-height measurement is proportional to transcript length; subsequent scrolling reuses cached heights. A window-width change requires height recalculation. Sustained 120 Hz has not been established by frame-time measurements and must not be claimed from a successful build or screenshot.

People and tags remain fully hydrated at launch through `FileEntityStorage.load`. Person includes notes and voice samples. Recognition, association menus, summaries, and context views assume complete arrays, so silently limiting them to a page would break correctness. Future entity scaling needs indexed name/count queries, direct ID hydration, searchable paged assignment menus, and scope-filtered voice samples. No million-person or million-tag scalability claim is supported.

## Validation

The first compact SwiftUI release passed 15 focused speaker/edit lifecycle tests. Its Preview screenshot confirmed compact columns, and native automation verified speaker autocomplete/reassignment without starting playback. After the user explicitly approved a previously rejected synthetic click, final SwiftUI interaction checks verified double-click text editing, Escape cancellation, Return saving, and single-click playback. The final storage fix eliminated the initial fixture conflict. Data settings showed the expected path, index size/rebuild row, and 2 Meetings, 2 People, 2 Tags, 0 Tasks; rebuilding completed and retained counts. Its two-record rebuild was too fast to capture the progress state.

The native table replacement compiled and passed the original 7 transcript tests. New native tests cover width/text height-cache invalidation, repeated cached measurements, cancellation, active-edit cell reuse, the real window field editor, and hover suppression while scrolling. The integrated release passed 375 tests across 77 suites and formatting checks. Its Preview screenshot confirmed the compact header and wrapped native rows, but interaction validation found stale hover backgrounds and an editor that selected text without accepting input. A window-backed editor regression reproduced the latter; removing the redundant responder change fixed the shared field editor. Double-click activation is deferred until native mouse tracking finishes.

The corrected release passed 16 focused tests across native transcript, file monitoring, and meeting prefetch suites. Isolated Preview validation with 10,000 segments confirmed double-click editing, exact Return save, Escape cancellation, speaker autocomplete and reassignment without starting playback, and single-click playback from the selected segment. A 15-page scroll reached segment 436 with recycled native rows; the after screenshot showed a single hover highlight rather than accumulated highlights. The compact header and wrapped text remained aligned. This validates behavior and layout, not sustained display frame rate; trackpad feel still needs the user's hardware check. The existing Command Line Tools missing linker search-directory warnings remain; no new deprecation warning has been observed.
