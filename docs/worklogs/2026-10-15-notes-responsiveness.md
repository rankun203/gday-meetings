---
title: Keep Notes typing independent of library updates
date: 2026-10-15
status: complete
scope: macos-notes-performance
---

# Problem

Typing published the entire meetings collection for every character. The supplied CPU profile showed sustained typing intervals dominated by SwiftUI layout, with recording animation sharing the busy main thread. Native editor updates also requested layout when their content had not changed. Image decoding and preview generation ran synchronously during editing and image interactions.

# Implemented solution

NotesStorage owns a separate observable NotesDraft for each open document. The native editor observes that draft. Character changes schedule existing asynchronous persistence without publishing the library. The meeting snapshot accessor and managed task input capture include the latest draft; explicit flushes synchronize the collection. Canonical recording persistence applies the same draft overlay. Reading mode observes the same document through a separate narrow view.

Unchanged native updates no longer request layout. Marked text is protected from stale representable reloads. Image import, resize, normalization, and thumbnail preparation run outside the main actor. Preview mutations use a serial actor; cached normalized results include source file versions. Applying results checks the document or image request revision. Normalization cannot cancel a pending user image operation. Explicit saves and switching to reading wait for pending image preparation.

# Reasoning

The design follows [Apple’s SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance): narrow dependencies and eliminate unnecessary updates before changing scheduling priorities. Autosave already used a background actor; slowing saving would not address the measured layout work. Native text editing continues to own selection, undo, and input-method composition. Rendering and metadata changes remain on the main actor; file access and image processing do not.

The existing synthetic Notes preview, captured by the parent reviewer before editing, provides the visual baseline. Layout and controls remain unchanged by this task. Timestamp sizing is a separate reviewed change.

# Validation

Added a deterministic test for 200 edits to a long synthetic document: zero expected MeetingStore broadcasts, one draft broadcast per edit, and current snapshots before and after durable persistence. Additional checks cover unchanged representable updates, marked text, and stale asynchronous image results. Mounted image tests await preparation and retain their undo, selection, timeline, and image identity assertions. The existing capacity harness now waits for image import before measuring completed image operations.

The final isolated release build passed in 134.33 seconds. Combined regression passed 153 of 154 tests; the remaining image-view assertion exposed a test waiter returning after a canceled request rather than its replacement. After correcting that waiter, all five NotesImageEditorTests passed in 0.444 seconds. Two additional runs of the formerly failing case passed in 0.257 and 0.273 seconds with the compiled test bundle. No further source changes followed. Synthetic preview checks confirmed typing, native undo, and recording Edit/saved Read behavior.

The opt-in release capacity harness completed 100 insert-and-layout operations at 10 Hz for each of two documents with four image references and synthetic recording state. For 10 KiB, p50/p95/max were 14.3/22.8/36.9 ms; for 100 KiB, 22.2/32.2/39.0 ms. No operation exceeded 100 ms and no scheduled edits were skipped. This component workload includes a one-millisecond yield and forced layout/display; it does not run real capture or measure physical keyboard-to-display latency. Metrics are in `/private/tmp/gday-notes-capacity-verified.jsonl`. There is no matched before/after baseline. These tests do not establish real keyboard-to-display latency. The proposed p95 target remains a measurement goal, not a reported result. Actual Chinese input-method interaction needs manual validation beyond the synthetic marked-text test.

# Technical debt

The application still uses the legacy observable MeetingStore for non-editor operations. Explicit operation boundaries synchronize drafts into that collection; consumers that need current content must use the meeting snapshot accessor. Replacing this bridge requires moving other meeting content to independently observable documents. This change does not claim to complete that broader migration.

Image paste preparation rejects applying its result if the document changed while processing and asks the user to paste again, preserving newer text. Supporting insertion anchors that track concurrent edits would remove that limitation. Clipboard format conversion still requires AppKit on the main actor when no PNG or TIFF representation is available.

Export and server archive packaging retain existing direct preview preparation calls outside the new image actor. Their entry points flush Notes first, but later editing can overlap long-running packaging. A follow-up should prepare and pin the export snapshot through the image actor, then make packaging read-only. This task serializes editor and Notes autosave mutations without restructuring archive workflows.

Validation retained two existing linker search-path warnings for missing Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` directories. No deprecation warning was reported.
