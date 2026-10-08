---
title: Responsive search result layout
date: 2026-10-08
status: complete
scope: swift-app-search
---

# Responsive search result layout

## Problem

Fixed row heights and metadata offsets left gaps below titles and short passages. Source badges were too wide with uneven padding, and excerpts retained boundary whitespace. A 750-point page cap wasted horizontal space in wide windows; timelines and excerpts remained below titles.

## Implemented solution

- Remove the page width cap. At table column widths of at least 580 points, place title, summary, source, and date in a left column using 32% of the content width. Top-align the timeline and excerpt in the remaining right column with a 24-point gap. Stack the sections at narrower widths.
- Measure native stacks at the current column width, using the same cell configuration for display and a reusable measurement cell. Lay out wrapped labels before requesting their fitting height. Reload reusable rows when the column resizes, preserving selection.
- Omit absent summaries, timelines, excerpts, and scores. Place scores below the content. Fit source badges to their labels with balanced padding; trim excerpt boundaries without changing saved text.
- Refresh timeline backing contents on cell reuse so unchanged intervals remain visible after resizing or toggling scores.

Changes are in `LibrarySearchResultsView.swift`; the search section of `UI_DESIGN.md` describes the final behavior. Full-meeting navigation and playback are documented in `2026-10-08-search-result-meeting.md`.

## Reasoning

Inspected the user’s annotations and captured the existing synthetic Preview before editing. The intended wide layout uses two top-aligned columns while retaining the rank/play rail and optional score footer. Narrow layouts keep readable text widths by stacking the same views.

Native automatic row heights retained stale measurements when the stack orientation changed. Explicit Auto Layout fitting through the table delegate resolves that issue without fixed height estimates or separate layout implementations. Column resize reloads also refresh visible cell constraints. Independent review identified an asynchronous selection race; the coordinator now reads the current selected result ID when the deferred reload executes and suppresses selection notifications while restoring it. This avoids selecting the wrong row if search results changed meanwhile.

## Technical debt

None.

## Validation

Formatting, lint, and diff checks passed. The final isolated release build passed, including deployment-target checks, packaging, and signature verification (`responsive-verified-release.log`, revision `ca8c37e-responsive-search-verified`). Builds use the isolated source copy at `tmp/search-open-validation`, preserving running development and installed apps.

The temporary native fixture uses production table, cell, and timeline source with synthetic model inputs. Verified widening from 750 to approximately 1152 points and narrowing to 552 points, titles with and without summaries, wrapping titles, one-line and four-line excerpts, untimed notes, scores on/off, and Light/Dark appearance. Resize checks exposed stale heights and clipping; measuring after layout and reloading cells resolved both directions. Verified selection survives widening and narrowing after deferring the row reload until AppKit finishes its column resize. Capture: `responsive-selection-final.png`.

Captures under `tmp/search-open-validation`: `responsive-before.png`, `responsive-wide-final.png`, and `responsive-narrow-dark.png`. The full release Preview (`ca8c37e-responsive-search-final`) shows the uncapped two-column page, opens the full meeting and plays from 0:08 when its transcript result is clicked, and restores the query and selected row with Back. Capture: `responsive-app-final.png`. The final selection-only correction was then verified in the native fixture. Thirty existing search, timeline, and deferred-playback tests passed during the navigation change; the responsive follow-up uses native UI checks.

### Passage width threshold

Lowered the row breakpoint from 720 to 580 points after inspecting the stacked layout at a roughly 642-point fixture window. The existing 68-point rail/insets, 32% metadata share, and 24-point column gap leave `(580 - 68) × 0.68 - 24 = 324.16` points for the passage. Three synthetic ten-word sentences measured 294, 316, and 382 points using the actual 13-point system font; 324 points is a practical approximate target, not a guarantee for every ten-word phrase. The change retains the existing layout and reflow behavior. Captured the same approximately 642-point window before and after the change, then resized just below and above the new threshold (approximately 608- and 623-point windows). Two-column content, four-line excerpts, scores, and keyboard selection remain intact in Light and Dark appearance. Captures: `breakpoint-before.png`, `breakpoint-side-by-side.png`, `breakpoint-below.png`, and `breakpoint-above.png`. Final release validation passed with all delegated fixes (`search-trigger-release.log`, revision `ca8c37e-search-trigger`); formatting, lint, source-copy comparison, and diff checks passed.

### Independent review and behavioral checks

Two sub-agents reviewed the implementation and validation evidence. An ignored regression harness extracts the production resize, selection, and activation methods plus the Play closure into minimal synthetic model shims with a real `NSTableView`. All eight scenarios passed, including reordered/replaced results, later keyboard selection, coalesced resize notifications, activation clearing selection, and invalid activation. Parent independently inspected and reran the harness. Source: `tmp/search-open-validation/SelectionRegression.swift`; generator: `make-selection-regression.py`. The harness has no visible window and cannot validate first-responder behavior.

## Limits and environment

The full Preview uses synthetic content and silent playback. Its semantic model reports a missing LICENSE file, so Text search verifies the full page and the synthetic fixture verifies ranking details. Large-library performance, VoiceOver, increased contrast, reduced transparency, real audio, and active-recording UI were not measured.

Host: macOS 26.6.2, Swift 6.4, SDK 27.0, deployment minimum macOS 26. Builds report existing missing Command Line Tools linker search directories; no source deprecation warnings appeared. Verify those environment warnings with updated Command Line Tools or a complete Xcode toolchain. Unrelated experiment files were left unchanged.
