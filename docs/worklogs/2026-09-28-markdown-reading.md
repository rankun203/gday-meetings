---
title: Continuous Markdown reading and summary actions
date: 2026-09-28
status: validating
scope: swift-ui
---

# Problem

Summary and Notes reading mode created separate selectable SwiftUI blocks. Selection could not cross paragraphs, task markers were inert glyphs, citations were plain text, and spacing was wider than the Rust reader. Single-line meeting summary previews reserved room for an empty second line.

# Implemented solution

Use one native TextKit document for reading. Match the Rust reader's restrained hierarchy with semantic native fonts, proportional line spacing, compact list items, native bordered tables, and bounded image thumbnails. Only a changed document or reading configuration rebuilds attributed text; scrolling and playback ticks do not parse Markdown. Selection spans paragraphs, lists, and tables.

Equal-sized, 14-point checkbox drawings and full wrapped-row click targets update their source Markdown and retain notes timing metadata. Citation links recognize bracketed minute/second and hour/minute/second timestamps and ranges; playback starts at the first time. Inline code and existing links are not rewritten. Task rows show subtle hover feedback and a pointing-hand cursor. Dragging retains native text selection, double-click selects text, and citation links take precedence over task toggles. Native link cursors provide link hover feedback. External links are restricted to HTTP, HTTPS, and mail; original image links resolve through the existing safe notes asset path validator.

Remove the To-Dos tab. Existing independently extracted to-dos remain editable in a collapsed To-Dos section inside Summary; no data migration or duplication into summary Markdown occurs. Meeting preview text drops whitespace-only lines and measures up to two actual text lines.

# Reasoning

The Rust reader uses GitHub Markdown styles, one browser selection surface, persisted task markers, and citation navigation. A single native text document provides those reading interactions without a WebKit process, injected HTML, continuous timers, or independent per-paragraph selection. Native font metrics approximate Rust's CSS rather than claiming pixel-identical rendering.

# Validation

Reviewed the user's supplied Summary screenshot and isolated Preview baseline captured by the root agent. Added focused tests for citation conversion, checkbox/timing preservation, continuous document content, and blank summary preview sizing. Consolidated build, tests, and changed-screen validation are handled by the root agent.

# Technical debt

The existing focused Markdown block parser remains; it is not a complete CommonMark/GFM parser. Nested source forms outside its supported set remain literal. Full CommonMark compliance would require replacing this parser while retaining source offsets for checkbox edits. Task-row hover uses native text-input geometry for visible paragraphs rather than per-row views; checkbox images are native inline text attachments. Copied tasks retain Markdown checkbox syntax; VoiceOver custom actions expose completion. The reader holds one rendered summary/notes document in memory, appropriate for meeting documents but not a streaming viewer for arbitrarily large files.

## Checkbox validation refinement

The initial native geometry check exposed a real margin hit-testing issue: AppKit returns the end of the document when an insertion query falls inside the text container's top/left margin. Cache task source ranges on content changes, then binary-search native paragraph geometry for visible rows. This avoids margin queries and works independently of the layout engine. The measured fixture retained TextKit 2 after a native table.

All six focused Markdown tests passed after this fix, including a wrapped task following a table, equal checked/unchecked marker sizes, the full last-line click target, citation precedence, adjacent citation spacing, source/timing preservation, and compact summary previews. Final hover appearance and interaction checks are performed in the consolidated Preview build by the root agent.

## Reading selection and task alignment

The task hover screenshot exposed asymmetric leading in native paragraph layout. Keep text in its existing flow, and derive task background bounds and checkbox centers from the actual baseline and font ascent/descent. Apply equal padding above and below the visible text, including wrapped tasks.

Copy in reading mode now targets Markdown source rather than displayed glyphs. Inline parser source positions identify selected text without searching for repeated phrases. Partial emphasis and links retain balanced syntax; transformed citations map back to their original complete timestamp markers. Block metadata retains headings, list/task prefixes, code fences, and table coordinates. Partial table copies preserve selected cells with blank unselected positions rather than leaking unrelated cell contents. Editing mode retains normal clipboard behavior. Focused and final Preview validation are pending.

The native geometry regression now verifies balanced first/last-line text padding and checkbox centers after a table, including a wrapped task. Source-copy tests cover partial strong text, links, adjacent citations, mixed list/task selection, tables, duplicated phrases, entities, escaped punctuation, code fences, and composed Unicode offsets. Rendering and scrolling perform no copy aggregation; source contexts are created with content, and copying resolves only on the copy action.

All 20 focused tests across the native reader, inline source mapping, and block selection suites passed. Boundary-only selections do not copy stray list/heading prefixes; images and dividers copy their source atomically. Full blocks preserve original Markdown; partial formatting may canonicalize equivalent emphasis delimiters or link angle brackets. No compatibility bridge was added. The existing Command Line Tools linker search-path warnings remain; consolidated release and visual comparison are tracked by the root task.

## Visual alignment correction

The consolidated Preview check caught stacked checkbox drawings after scrolling, despite the first geometry test passing. That test repeated the same baseline-delta calculation as the implementation, so it did not independently validate placement. Replace the text-input baseline delta with TextKit 2's actual line fragment glyph origin, translated through the fragment and text-container origins. The revised regression compares markers with native line rectangles and verifies separated task rows before and after scrolling. Final visual comparison remains required after the corrected build.

The second Preview check showed that resolving raw storage offsets through TextKit content locations still misplaced a checkbox after a native table. Remove the custom checkbox overlay entirely. Each checkbox is now a 14-point native text attachment in its own paragraph; AppKit lays it out with the text. Full-row hover/hit regions use native input rectangles only. An exact default Preview summary fixture verifies both attachments and retained Markdown task syntax on copy. This removes the separate checkbox placement mechanism rather than adding another offset correction.

Final release Preview validation passed: checked and unchecked markers have equal size and align with their respective text rows after scrolling past the table. Clicking blank space across Alex's row toggled only Alex and updated its strikethrough. The earlier Copy-to-Notes check retained Markdown headings, lists, table syntax, citations, and task markers; the attachment regression additionally checks source copying after this final change. Pointer-only hover appearance was not rechecked because the automation interface does not expose pointer movement without a click or drag.

## Unordered-list spacing

The supplied Attendees screenshot and the captured Preview Summary showed small dots with a wide gap before the text. Increase the bullet glyph's font from 14 to 15 points and reduce unordered-list text indentation from 22 to 18 points. Wrapped lines use the same inset. Ordered lists and task rows retain their existing layout. This is a rendering-only adjustment with no additional technical debt. Release Preview comparison passed: the dot is larger and the text starts closer to it, with wrapped text aligned to the same inset.

## Checkbox stability and Notes controls

**Problem:** Clicking a task replaced the entire attributed document and collapsed selection before restoring a raw scroll offset. Deferred native layout could shift the viewport. Every clip bounds notification cleared hover, and pointer entry/cursor updates did not restore its background. The separate extracted To-Dos panel duplicated Summary tasks. Notes used a large button inside the document card.

**Design and evidence:** Inspected the user's scrolled Summary screenshot and captured the Preview Summary and Notes screens before editing. Keep the Summary viewport and selected text stationary while only task decorations change. Remove the separate To-Dos panel. Move Notes mode selection into a compact native two-icon segmented control on its own row above the card, following the supplied Finder control reference.

**Implemented solution:** Detect a single Markdown task-marker toggle and update attributes only for its existing block. Keep the displayed string, paragraph/table objects, and selection intact. Refresh copy metadata so copied Markdown reflects completion. Track actual clip origin changes rather than all bounds notifications. Update hover on pointer entry, movement, and cursor updates, and enable mouse-moved events in the containing window. Removed the To-Dos panel and its unused editor code; existing stored task data remains intact. Notes now has a small native Edit/Read picker outside the card and flushes pending notes before mode changes.

**Validation:** Added a hosted long-document regression with a native table, wrapped Chinese tasks and citations. It repeats toggles while scrolled, checking final-line geometry, row position, scroll origin, selection, hover restoration, strikethrough, and Markdown copy. All 426 tests in 85 suites passed, along with format and lint checks. Preview confirmed the compact Notes control, accessible mode names, and switching in both directions. The first Summary visual check caught an attribute range ending at the marker; using the longest block range fixes the complete task decoration. Final rebuilt Preview screenshots confirmed that clicking the blank portion of a task row checks and unchecks it, applies and removes strikethrough, retains hover, and leaves the table, heading, rows, and scroll position stationary. The isolated fixture validates the interaction; the regular app and personal library were left untouched during these checks. Builds retain the existing Command Line Tools missing search-path warnings; no new deprecation warnings were introduced.

**Technical debt:** The marker update still renders a candidate attributed document to obtain correct copy metadata, but only task attributes are applied to the live document. This work happens on content changes, never on pointer movement or scrolling. A future block renderer can remove that parse cost if profiling warrants it. The existing incomplete CommonMark support remains unchanged. Stored extracted task data is retained for export; no data migration or deletion is introduced.

**API reference:** [AppKit text storage](https://developer.apple.com/documentation/appkit/nstextview/textstorage) distinguishes attribute updates from character replacement. The fix retains native text storage and tracking areas instead of using a separate per-row view or compensating scroll animation.

## Notes control alignment

**Problem and design:** The user requested right alignment for the Notes mode control. Captured the existing Preview with the control on the left. Place the same compact control against the document card’s right edge on its own row.

**Implemented solution:** Move the flexible spacer before the picker and update the UI design rule. Mode behavior and dimensions remain unchanged.

**Validation:** The rebuilt Preview screenshot confirms the control aligns with the card’s right edge. Switching to Read works. Checked system light appearance; the full appearance and window-size matrix was not repeated for this alignment-only change. No new behavioral test was needed.

**Technical debt:** None.

## Chinese bold labels

**Problem and evidence:** The supplied Summary screenshot shows literal `**` around a Chinese conclusion label. Read-only inspection of that meeting’s `summary.md` confirmed a bold label followed immediately by body text, with no separating space after the closing marker. The native Markdown parser treats this punctuation boundary as literal text.

**Implemented solution:** At reading time, insert a space after a bold CJK label ending in Chinese punctuation when the next character is a letter or digit. Exclude inline code and escaped markers. Keep the original saved source and full-block copy; use parser-input positions for partial selection so repeated labels retain correct boundaries. Add the case to the synthetic Preview.

**Validation:** All 10 focused Markdown tests and the final full run of 427 tests in 85 suites passed, along with formatting, lint, and the release Preview build. Coverage includes repeated labels, native bold font traits, partial and full-source copying, citations, escaped markers, and literal inline code. The final Preview screenshot shows the generic Chinese label in bold, body text in regular weight, and a clickable timestamp with no literal markers. The first parallel test run failed the existing hover-delay timing check; an isolated retry and the full rerun passed. Builds retain the existing missing Command Line Tools library/framework search-path warnings; no new deprecation warnings were introduced.

**Technical debt:** This is a narrow reader compatibility adjustment for generated CJK labels, not a replacement Markdown parser. It adds a visible separator without rewriting stored documents. Retain it until the parser supports the intended adjacent-punctuation rendering or summaries consistently emit the separator; keep source-copy tests during any replacement.

**Reference:** [CommonMark emphasis rules](https://spec.commonmark.org/spec#emphasis-and-strong-emphasis) require a closing marker after punctuation to be followed by whitespace or punctuation. The reader adjustment deliberately accepts the generated label style shown in the screenshot.

## Synthetic examples only

**Problem:** Some regression text and a Rust comment used project-specific content or attendee names. Benchmark documents named a personal meeting and its library identifier.

**Implemented solution:** Replace those examples with generic wording, remove personal benchmark identifiers, and add an explicit synthetic-content rule to repository instructions. Search the repository for known meeting titles, attendee names, project terms, and Chinese passages; preserve genuine application identifiers and unrelated dependency metadata.

**Validation and limits:** Reviewed source, tests, fixtures, comments, and documentation matches. This sanitizes the current repository tree; it does not rewrite published Git history or alter personal meeting content. Existing benchmark measurements remain historical observations, with identifying labels removed.

**Technical debt:** Previously published text can remain in Git history; a history rewrite would require a separate coordinated change because it replaces commit identities.
