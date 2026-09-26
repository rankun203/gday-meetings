---
title: Markdown notes with timeline links
date: 2026-09-26
status: implemented
scope: swift-app-notes
---

# Markdown notes with timeline links

## Problem

Notes used a plain editor and rewrote the whole library on every keystroke. They had no recording times or playback links.

## Implemented solution

- Added a TextKit 2 editor with visible Markdown syntax, paragraph styling, list continuation, formatting commands, task toggles, and native editing.
- Added hidden timeline comments, a fixed time gutter, Command-click and Command-Return playback with a three-second lead, and a same-meeting clipboard format.
- Added atomic `notes.md` persistence with a half-second debounce. Focus changes, editor dismissal, recording stop, and quit flush pending notes. A failed quit flush keeps the app open.
- Library version 3 backs up the old index before creating notes sidecars. Standalone meeting JSON keeps notes; the library index omits them. Metadata failures preserve durable or pending notes.
- External edits reload when notes open. A concurrent external copy is preserved before the app saves its draft.
- Summaries and Markdown exports convert markers to readable time prefixes. JSON and archive retain markers. Preview includes timed and untimed notes.

## Reasoning

The native text view provides macOS text input, undo, spelling, accessibility, and selection. Saved Markdown is independent of styling, so styling mistakes cannot change the note text. Notes save separately from meeting metadata to keep typing inexpensive.

## Technical debt

- Styling is a focused regular-expression layer rather than a complete Markdown parser. Nested constructs may receive simpler styling, but the source remains unchanged. Adopt a pinned parser if real notes expose unsupported formatting.
- Notes use the existing recording-duration fallback specified in the accepted design; its start date is set after capture begins and can lag the audio timeline. Expose the capture host-clock elapsed time and use it for new notes to remove that offset.
- Images and asset exports remain the explicitly planned later phases; phase 1 leaves image Markdown as text and does not fetch remote images.

## Validation

Sixteen focused notes/library tests passed, including native undo/redo, same-meeting and cross-meeting paste, debounce, migration, external edit conflicts, failed writes, code/table timing, Unicode, and invalid marker times. The combined live/notes run also passed. UI review found gutter buttons absent from the accessibility tree; explicit visible children were added. The packaged Preview now exposes all visible gutter buttons, and activating the 0:12 button starts playback at 0:09. The full 241-test suite, formatting, lint, and Preview packaging passed. Preview confirmed Markdown styling and Command-Return playback from 0:09 for the line timed at 0:12. Native gutter accessibility and keyboard playback checks passed. This Mac cannot establish macOS 14/15 behavior; compatibility checks on those systems remain required.

The existing Command Line Tools linker warnings name absent framework and library search directories. No deprecated API warning was reported for the notes implementation. GitHub, Obsidian, and VS Code rendering checks remain untested; markers use HTML comments, and the source round-trip tests preserve unrelated comments.
