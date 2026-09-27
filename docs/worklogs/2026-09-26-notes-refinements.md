---
title: Notes reading, external edits, and phrase times
date: 2026-09-26
status: implemented
scope: swift-app-notes
---

## Problem and design before implementation

The current Notes screenshot was captured and inspected in isolated Preview before changes. Markdown delimiters remain visible in the editable text, with line times in the left gutter. Keep this editor stable. Add an explicit Read view that hides formatting syntax, renders headings, lists, code, images, and tables, and retains timestamp playback. Editing remains a separate unchanged layout; switching modes must flush safely.

Watch the selected meeting directory for changes to `notes.md`, including atomic replacement. Reload external text only when no app draft is pending. If both changed, keep the app draft and preserve the external text using the existing numbered conflict-copy behavior. Stop watching when the meeting closes; do not poll continuously or watch every meeting.

Extend the existing inline time-marker format to recognize several phrases on a line. Appending text after at least 15 seconds of inactivity creates a new phrase time; typo edits keep their existing time. Preserve hidden markers through edits and undo. The paragraph gutter keeps its first time; Command-click uses the clicked phrase’s time.

## Implemented solution

Added `NotesFileWatcher`, selected-meeting reload/conflict handling in `NotesStorage`, and a stable workspace lifecycle shared by Edit and Read. Watch callbacks reject stale meeting IDs. Atomic replacement and delete/recreate are handled without erasing text during a temporary missing-file interval.

`NotesDocument` now parses and round-trips multiple phrase markers, preserves their UTF-16 offsets through editing, and supports phrase-aware private clipboard slicing/pasting and Command-click lookup. The editor adds a marker on a timed line when text is appended after a 15-second pause. Existing untimed text is not retroactively stamped.

`MeetingNotesWorkspace` adds explicit Edit and Read controls. The read-only view renders headings, lists, quotes, fenced code, aligned tables, inline formatting, safe local images, and playback timestamps. Mixed image/prose or unsupported image forms stay visible as literal source. Local image thumbnails are bounded to 1,600 pixels and never fetch external URLs.

## Validation

The first integrated run compiled; it found a missing inline-code exclusion in the shared parser and a debounce test that needed bounded polling under load. Both were corrected. Added regressions for phrase round trips, emoji edits, split/delete, private clipboard, table escaping/malformed tables, mixed images, atomic saves, external conflicts, file recreation, and stale watcher callbacks. The integrated 308-test suite, formatting, lint, and production build passed. Read-mode rendering and external reload after Edit/Read switching have not been visually checked. Native validation was deferred to preserve the user’s active validation app; watcher, parser, and phrase behavior are covered by automated tests. The user's open Preview and installed recording remain untouched.

## Technical debt

The proposed 2027 TextKit gutter APIs are not available in the current stable SDK. Keep the existing macOS 14-compatible gutter. Reassess the supported SDK and deployment availability when those APIs ship; do not invent availability gates for future symbols.

The reading view uses the app's supported Markdown blocks and Foundation's inline parser rather than vendoring a complete GFM parser. Unrecognized image layouts remain literal, and source text is never rewritten by reading. If nested Markdown or HTML rendering needs expand, adopt a source-range-aware parser under the repository dependency policy and retain the literal fallback.

Asset-only original replacements do not trigger a Notes view reload when `notes.md` is unchanged. Image metadata is rechecked before save/export/archive; the reader reloads when its document or image reference changes. If immediate asset-only refresh becomes necessary, add a scoped assets-directory event watcher and preserve the current no-poll lifecycle.
