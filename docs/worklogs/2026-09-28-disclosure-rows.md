---
title: Consistent expandable section headers
date: 2026-09-28
status: complete
scope: swift-ui
---

## Problem

Speakers and the recording visualization preview used the default disclosure triangle, without Recording Options’ full-width clickable header and hover feedback. The user supplied screenshots of both treatments; the existing Preview screenshot confirmed the mismatch before editing.

## Implemented solution

Extracted Recording Options’ existing style into `AppDisclosureStyle` and applied it to all three DisclosureGroup sites. Recording Settings already uses a full-row button and the same ActionButtonStyle feedback. Documented the shared interaction, hit target, appearance, keyboard, accessibility, and Reduce Motion requirements in UI_DESIGN.md.

## Reasoning

Reuse the reference control’s behavior so all disclosure groups share one implementation. Keep the specialized Recording Settings summary and its existing full-row interaction.

## Technical debt

None.

## Validation

Release and Preview builds and Swift lint passed. Existing Command Line Tools missing linker search-directory warnings remain. Isolated Preview verified Speakers expansion and collapse by clicking the empty right-hand part of its header, and the shared preview disclosure expanded correctly. Screenshots in System/light and Dark appearance confirmed layout and state labels. Hover uses the unchanged Recording Options ActionButtonStyle; the automation pointer did not provide a reliable hover-only screenshot. Full keyboard traversal, small-window, increased-contrast, and Reduce Motion checks were not repeated. No additional unit test was added for this shared-style extraction.
