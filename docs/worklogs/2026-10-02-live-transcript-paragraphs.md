---
title: Continuous live transcript paragraphs
date: 2026-10-02
status: implemented
scope: swift-transcript-presentation
---

# Continuous live transcript paragraphs

## Problem

The user's recording screenshot showed one sentence broken into repeated timestamp and speaker rows at recognition chunk boundaries. Short unattributed words introduced additional breaks. The native renderer displayed every recognition phrase independently even when the speaker remained unchanged.

## Implemented solution

`LiveTranscriptParagraphs` groups consecutive chunks from the same source, recognition session, scoped speaker, and person assignment. Groups stop at terminal English or CJK punctuation, an overlap, a gap longer than 0.8 seconds, or 30 seconds of text. Unknown and identified labels remain distinct. Manual overrides and unresolved timing are hard boundaries. English chunks receive a separating space when needed; adjacent Chinese and Japanese text does not acquire extra spaces.

Each displayed paragraph carries a captured phrase spanning its complete text and time range. Editing or assigning that paragraph uses this anchor; subsequent recognition outside the captured range remains separate. Existing override anchors cannot expand through later grouping. The raw checkpoint phrases are unchanged. The same finalized grouping supplies adopted transcript segments and speaker entries, so newly saved live transcripts retain the paragraph layout. Existing saved transcript arrays are not rewritten.

The native renderer accepts explicit provisional text ranges. Only the partial substring is underlined; the newest active partial retains the original two-word color trail at translated offsets. Finalized text in the same paragraph keeps its normal style. Selection, editing, attribution, and scrolling still pause Follow Live until explicitly resumed.

## Reasoning

The user screenshot was inspected before implementation. Grouping only display text without updating the edit anchor could replace the wrong passage, so paragraph text and the captured time range are produced together. Sharing the grouping with adoption avoids a different layout immediately after stopping. Speaker inference remains a separate operation; presentation does not fill attribution gaps or merge identities.

## Validation

Focused regressions cover English and Chinese grouping, terminal punctuation, speaker/source/session changes, pauses and overlaps, manual override boundaries, adoption without raw-phrase mutation, partial-only underlining, translated red-word offsets, and editing or attributing a captured paragraph after recognition extends beyond its end. The production grouping, projection, and native renderer compiled in an isolated fixture. Light and dark captures under `tmp/live-transcript-unification/screenshots/paragraphs-*.png` were inspected: repeated chunk badges collapse into one sentence, Chinese joins without inserted spaces, and only the pending suffix is underlined and colored. No real recording was changed.

Strict formatting and diff checks pass. The integrated run passed 600 tests in 107 suites. After the final punctuation-preservation correction, 71 transcript tests in eight suites passed. Assignment-only reconstruction now preserves exact text inside each original recognition phrase and uses the shared joining policy only between phrases; English punctuation and Chinese regressions cover timed and untimed input. The existing visible-cell playback regression and pre-update highlight clearing are retained.

The isolated `make build-macos` release build passed in 131.88 seconds, and strict code-signature verification passed. All 280 application source files match the validated snapshot. Existing Command Line Tools linker warnings remain for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths; no deprecation warnings appeared. Toolchain cleanup remains tracked in the macOS release CI worklog. Hosted CI is checked after pushing.

Capture validation used isolated native components; a new live recording and interactive editing in the complete running app remain user acceptance checks. The current recording was not stopped or replaced.

## Technical debt

Sentence boundaries use terminal punctuation, not linguistic sentence parsing; abbreviations can end a group. The 0.8-second gap and 30-second maximum are explicit presentation policies rather than accuracy claims. If listening review shows poor paragraph boundaries, adjust these policies with regression fixtures. Historical saved segments are intentionally not migrated; a future explicit reflow operation would need to preserve manual edits and transcript history.

## Lighter word trail follow-up

The supplied light-appearance screenshot showed the preceding word in dark red. History at `bc9813a` and the September 27 word-trail worklog describe a lighter preceding word, but the implementation mixed red with the primary text color. That darkens red in light appearance. The native renderer now mixes toward white in both appearances; the newest word remains red. This preserves the intended lighter trail rather than copying the historical light-appearance defect. Word selection, underlining, and finalization are unchanged. No new technical debt is introduced.

Isolated light and dark captures compare the exact historical SwiftUI implementation, the previous native color, and the corrected white blend. The historical and previous native paths both darken the preceding word in light appearance; the corrected paths agree visually and stay lighter in both appearances. Captures are under `tmp/live-word-color-audit/`. All 71 focused transcript tests passed, as did formatting and lint. The isolated release build passed in 163.75 seconds, and strict signature verification passed. All 280 application source files match the validated snapshot. The same documented toolchain search-path warnings remain. Hosted CI is checked after pushing.
