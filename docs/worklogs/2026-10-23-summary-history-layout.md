---
title: Summary History sheet layout
date: 2026-10-23
status: complete
scope: macos-summary-history
---

# Problem

Summary History used the large list-and-preview sheet dimensions for every state. The supplied screenshot showed a floating header and footer, excessive blank space, an off-center empty message, and an unavailable restoration action. The empty message also suggested generating a summary when the meeting could already contain one.

# User intention

Correct the Summary History sheet, preserve its original version-preview and restoration workflow, delegate implementation and validation, obtain an independent Claude Code Opus 5.5 review, and commit the reviewed change.

# Implemented solution

`SummaryHistoryView` gives loading, empty, and initial load-error states compact dimensions, with a top heading, a body that fills the available area, and Done at the bottom right. Empty history hides Use This Summary. When the meeting contains a current summary, the explanation identifies the existing summary and directs the person to generate another summary to save versions. Meetings without a summary retain the instruction to generate one.

Saved versions retain the larger list-and-preview layout and restoration controls. The list and preview fill the middle area. History reloads retain existing entries and the larger layout while refreshing. Initial load errors show their explanation and Reload History in the compact body; errors with existing versions retain inline recovery controls.

# Reasoning

The original October 14 design intended a secondary sheet for dated versions, provider/current markers, readable previews, and restoration that preserves displaced edits. The supplied screenshot was inspected before implementation. The concrete design uses an approximately 480 × 280-point compact state and the existing 820 × 560-point ideal size for populated history. Explicitly filling the content region anchors the heading and footer while centering unavailable/loading content. Separate sizing follows the content rather than padding an empty state to preview dimensions.

Opt-in synthetic Preview scenarios cover empty history with and without a current summary, unreadable history, and unreadable saved versions. The scenario hook runs after other meeting seeders so combined flags cannot overwrite the intended state.

The change preserves local asynchronous reads, stale-result guards, cancellation, selection, restoration, and persistence. It adds no migration or history backfill: current summaries and saved versions remain distinct records.

# Technical debt

None.

# Notes

## Independent review

Claude Code 2.1.303 used the requested `claude-opus-5-5` model with high effort for initial and follow-up reviews. It found no restoration or persistence regressions. Accepted findings restored the established No Saved Versions title, added a useful next action, moved the scenario hook after other seeders, clarified the fixture-test limits, and documented the flags. Follow-up review found no remaining correctness issues.

The review suggested predicting initial sheet size from current summary text. This was rejected because current text does not establish saved history, including the reported case. Loading remains compact and populated history expands after its local read; retained entries keep refresh sizing stable. This transition was exercised through the native sheet, although frame-by-frame animation was not measured. The shared inline error component was retained after a readable render check. A new presentation abstraction and tests of layout constants were unnecessary; production rendering and interaction checks cover the visual contract.

## Validation

- Final isolated `make build-macos` passed on macOS 26.6.2, minimum deployment macOS 26.0, SDK 27.0, including signing and platform verification. All 9 tests in `SummaryHistoryTests` and `UIPreviewSummaryHistoryTests` passed (including parameterized storage cases, preservation of edits, late results, missing artifacts, and failed-save rollback).
- `make format-macos` and `make lint-macos` passed in the isolated source copy. Task source matches formatted files. `git diff --check` passed.
- Isolated synthetic Preview rendered populated history, empty history with a current summary in light and dark appearance, and initial read failure. Heading and footer stayed anchored; empty/error sheets measured 480 × 280 points in captures. Populated history retained the list and readable preview.
- Selecting an older version enabled Use This Summary. Restoration updated the current marker and main summary; Escape dismissed the sheet. A deliberately corrupt synthetic history file produced the error state; removing that corrupt file and choosing Reload History recovered in place to empty history. Final release Preview also rendered both empty-summary and current-summary-without-history states; the revised title and three-line guidance fit the compact sheet without clipping. An unreadable saved-version fixture disabled restoration and displayed its error; repairing its synthetic generation files and choosing Reload History restored the preview and current marker.
- Build logs retain existing Command Line Tools linker warnings for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search directories. No deprecation warnings were observed. These are toolchain installation paths; changing application APIs would not resolve them. Follow-up is to validate after a Command Line Tools update.
- The test build also emitted five non-Sendable-to-`@Sendable` conversion warnings in the unrelated, pre-existing working-tree `LiveTranscriptionActivityTests.swift` at lines 11, 35, 69, 93, and 110. These are outside the committed change; follow-up belongs to the ongoing transcription task.
- Private build copies, source snapshots, logs, and fixture backups are under ignored `tmp/summary-history-layout/`; review logs are `/tmp/gday-summary-history-opus55-20261023-1135.jsonl` and `/tmp/gday-summary-history-opus55-followup-20261023.json`. Screenshots were captured and inspected through computer-use tooling.

The main app and its library remain outside validation scope; synthetic Preview fixtures are used. VoiceOver speech, slow-disk loading animation, and real provider generation are untested. The commit is limited to six summary-history source, test, and documentation files; unrelated working-tree changes are preserved. No push or installed-app replacement was requested.
