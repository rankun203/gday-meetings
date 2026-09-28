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
