---
title: Portable meeting ZIP export
date: 2026-10-09
updated: 2026-10-10
status: complete
scope: swift-meeting-export
---

# Problem

The meeting action exported text without audio or a standalone viewer. The supplied HTML prototype had the desired reading and playback layout but contained one meeting's fixed content and two hard-coded tracks.

# Implemented solution

- Rename the native action to **Export Meeting…** and use a ZIP save panel with “Choose a destination.” and an editable default filename. Suggest `meeting-<title>.zip`, replacing runs outside `a-zA-Z0-9-_` with a hyphen and trimming surrounding separators. Use `meeting-untitled.zip` when no title remains; cap the title component at 180 characters.
- Add `MeetingArchiveExport.swift`. Stage registered audio tracks, the canonical transcript as `transcripts.jsonl` when present, optional `summary.md`, referenced summary images, and generated `index.html`. Export no metadata, voice evidence, or unrelated folder contents.
- Bundle one plain HTML template through SwiftPM, with CSS and JavaScript inline. Reuse the prototype's content-free CSS and the existing Markdown block and inline parsers, including their Chinese-label handling. Summary timestamp citations start playback, and copied summary image links remain clickable. Embed escaped transcript and summary content for offline reading, relative audio paths, and resolved speaker labels in the viewer. Preserve the source transcript bytes in the JSONL file.
- Resolve the meeting folder through the notes worker, then run ZIP creation in a background task so large audio exports do not block note saves. Publish the completed archive atomically; reject unsafe filenames, symbolic-link input files, and destinations inside the meeting folder. Disable ZIP export during recording or audio import.

# Reasoning

The existing screenshot shows a native meeting menu and standard export action. Preserve that menu placement and use the system save panel. The viewer retains Transcript/Summary tabs, a single scrolling reading area, transcript search, follow control, and a fixed player. Generate track controls from the meeting instead of assuming two tracks. Reuse the app's Markdown parser for matching supported syntax without another dependency. Retain the internal text export paths for their existing callers and tests.

# Technical debt

None.

# Validation

- Captured the running app before editing and inspected the supplied menu image and prototype source. In isolated Preview, captured the updated native menu and save panel. The panel shows “Choose a destination.”, an editable `meeting-Synthetic-conversation.zip` default, and Export/Cancel actions.
- Exported a synthetic meeting through the production app flow and inspected the ZIP: two original WAV tracks, summary, transcript, generated HTML, and one referenced summary image. There are no CSS or JavaScript sidecars. The original development app and real meeting data remain untouched.
- Passed 42 checks in six suites: archive contents and replacement, byte preservation, filenames, unsafe paths, rollback, empty meetings, HTML escaping, summary links/citations/formatting, and existing storage/image/speaker export regressions. One suite is a temporary synthetic browser-fixture generator. The final isolated test target compiled the selected suites and their image helper; the normal manifest was restored afterward. JavaScript syntax validation passed.
- In Chrome, checked synthetic exports served by a loopback server with media range support: transcript search, Transcript/Summary tabs, timestamp playback, overlapping highlights, track mute, speed, seeking beyond the shorter track, a single track, empty states, and keyboard tab navigation. Inspected desktop and 390 × 844 layouts. Corrected compact player wrapping and suppressed empty track controls. No viewer-script errors appeared; unrelated browser-extension errors were present.
- The isolated `make build-macos` and Preview release builds passed packaging and signing on macOS 26.6.2, Swift 6.4, SDK 27.0, targeting macOS 26.0. The final Preview release build passed in 183.16 seconds. Sources and validation logs are retained under ignored `tmp/meeting-export-validation/` and `tmp/meeting-export/`; synthetic archives are under `/tmp/gday-meeting-export-preview/`.
- `make format-macos`, changed-file strict Swift lint, and `git diff --check` pass. Full `make lint-macos` reports existing formatting errors in `Models.swift`, `VoiceLibraryStore.swift`, and `LiveTranscriptView.swift`; broad formatting changes to those files were reverted to keep this task scoped.

Limits: browser automation rejects `file:` URLs, so direct local-file opening was not exercised through another browser route. Browser checks used synthetic HTTP-served WAV files; other codecs and browsers remain untested. Native checks used Preview without capture or hardware playback; the save panel was captured in Light appearance and the app was also inspected in Dark appearance. A further native interaction was interrupted by user input, so the window was left alone. Browser captures used dark appearance. The viewer has no remote dependencies or fetch calls. The shared Markdown reader preserves unsupported structures as readable source text.

Builds retain the previously documented missing Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search-path warnings. Repair or update the selected toolchain to remove them. No API deprecation warnings appeared. The macOS CI matrix will be checked after pushing.
