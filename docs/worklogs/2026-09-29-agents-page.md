---
title: Agents page and library instructions
date: 2026-09-29
status: complete
scope: swift-ui-and-library-guide
---

# Agents page and library instructions

## Problem

The meeting Chat tab duplicated an external coding-agent workflow. The library had no shared instruction file with launch commands, and the app had no way to display that file.

## Implemented solution

- Removed Chat from meeting capsule navigation. Transcript, Notes, Summary, and Data Privacy remain. Stored meeting chat and its service logic remain intact.
- Added **Agents** to the sidebar. It fills the main content area without an intermediate meeting list and renders the library root's actual `AGENTS.md` through the same native Markdown reader used by Summary.
- On startup, created the root guide only when missing. The generated Markdown contains a detailed reading guide, example Codex and Claude Code launch commands using the actual library path, a file tree, scoped search commands, authority/fallback rules, dates and IDs, speaker resolution, notes assets and timing, and history/journal semantics. It contains no meeting content.
- Kept the saved file as the single source of truth. Navigating to Agents reads it again, including custom edits. A complete initial YAML metadata header is hidden for display only; the saved file remains unchanged. Read-only libraries can display an existing guide.
- Used exclusive file creation to preserve customized guides and readable guide symlinks. A directory or unreadable target produces a clear error. Guide failure does not invalidate an otherwise usable library. No per-meeting guide generation or library-wide backfill is needed.
- Shell-quoted folder paths. Markdown fences extend beyond any backtick sequence in a command so unusual folder names remain a single copyable block.
- Added GitHub-style fenced-code presentation to the shared renderer: rounded backgrounds, inset monospaced text, and **Copy Code** buttons that copy raw code. Shared Markdown buttons and interactive markers show the pointing-hand cursor on hover.

## Reasoning

The guide applies to compatible agents generally; Codex and Claude Code are launch examples. It serves both people launching an agent and the agent reading the library. Rendering the actual file keeps the UI consistent with custom instructions and avoids maintaining a separate setup page. The reference Rust guide establishes the purpose, but Swift uses different storage paths, so the generated text describes the Swift files.

The guide was checked against the reference Rust instructions and Swift persistence code. It points to metadata, notes, summaries, transcripts, people, and tags, with concrete search examples to avoid unnecessary exploration. It explains empty duplicated content fields, base36 folder IDs, JSON calendar dates, relative transcript times, and the need to cite evidence. A command starts in the library folder; it does not confine the agent's filesystem access. The guide asks for read-only analysis unless changes are requested, and notes that the app's data-event journal does not monitor external coding-agent activity.

Commands use the plain launches requested by the user. Codex working-directory discovery was checked against the official [AGENTS.md guidance](https://learn.chatgpt.com/docs/agent-configuration/agents-md).

## Validation

- Parent inspected the existing sidebar, meeting tabs, and fenced-code presentation before implementation and owns final build and screenshot validation.
- Added tests for authoritative Swift files and generated launch commands; exclusive creation and preservation of customized files and symlinks; directory rejection; actual shell argument round-tripping with spaces, apostrophes, dollar signs, and backticks; fence handling; frontmatter display; root-only startup generation; disk edits; restart preservation; and retained meeting chat history.
- All 467 tests in 89 suites passed. Shared-renderer tests cover fenced-code geometry, raw code copying, and actual cursor events. The subsequent [controls layout change](2026-09-29-notes-controls-layout.md) replaces the initial copy-button row with a floating control and tests compact opening-block spacing.
- Isolated preview confirmed the four meeting tabs, saved-file rendering, reload after an external edit to the synthetic guide, plain command copying without fences, and readable code blocks in light and dark appearances. No agent command was executed.
- Formatting, lint, and whitespace checks passed. Builds retain the existing Command Line Tools linker warnings for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths; no source deprecation warning was reported. Repair or update the local toolchain to remove these environment warnings.
- Cursor behavior gives embedded buttons priority over the parent text view's cursor handlers and uses native SwiftUI pointer styling on supported macOS versions. Both Copy Code controls are exposed as accessibility buttons. The expanded guide's launch labels are plain text; the rest of its reference sections retain heading structure.

## Technical debt

Existing guides are never overwritten. This preserves customization but leaves generated absolute launch paths unchanged if a library is copied or moved. The guide can be edited directly; a future relocation flow should offer to update known generated commands without replacing custom instructions. Later storage-format changes also need an explicit refresh path that compares against known generated templates and preserves edits.

## Notes

Opening Agents reads the saved guide. It does not launch a coding agent or send meeting content. Installing an agent and running a copied command remain user actions.

Final preview check: the rebuilt isolated app displays both launch labels as body text, Copy Code buttons floating at the upper right of their code blocks, and the expanded guide below. Cursor behavior is covered by the event-level regression; the UI automation interface does not provide a hover action.
