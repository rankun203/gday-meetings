---
title: Emphasize the newest live word
date: 2026-09-26
status: in-progress
scope: swift-app-live-transcript
---

## Problem and design

The Voice Memos reference screenshot and the current isolated Preview Transcript were inspected before editing. Preview renders every provisional word in secondary text; it does not distinguish the latest word. Keep preceding words in the normal text color and emphasize only the newest provisional word in red. Use the recognizer’s latest timed word when available and Unicode word segmentation otherwise. Preserve the original text, whitespace, and punctuation. Final text returns to the normal color.

Merge provisional and finalized rows by their audio time. Keep recognition updates isolated in the Transcript tab, without a timer or per-frame publication. Apple’s provisional replacements remain authoritative: a changed sentence replaces the previous draft, and the final result settles it. This is recognition correction, not a separate grammar or language-model operation.

## Implemented solution

Added a pure presentation helper for chronological row merging and exact word ranges. The view colors only the newest provisional word; finalized and preceding text uses the normal color. Partial replacement is extracted into a tested helper without changing recognition behavior. Added an explicit synthetic multiple-provider Preview fixture for the remaining provider-menu checks.

## Validation

Formatting, lint, five focused tests, and the Preview package passed. Tests cover correction and final settlement, dual-source ordering, timed words, Chinese, punctuation, emoji, and preserved whitespace. The installed Command Line Tools still emits the documented missing linker-search-path warnings; no new deprecation warnings appeared.

An isolated dark Preview screenshot confirmed only the newest word “schedule” is red; preceding draft words and finalized text remain normal. CUA then reported user interaction with Preview, so appearance changes, resizing, and provider-fixture relaunches stopped. Light appearance, minimum-size layout, and one/multiple-provider screenshots remain unverified in this pass. Preview was left open, and the installed app was untouched. No real capture, model download, or transcription upload occurred.

## Technical debt

None planned. Word emphasis without timing identifies the latest recognized word, not an inferred audio playback position.
