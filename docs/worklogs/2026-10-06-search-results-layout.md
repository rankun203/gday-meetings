---
title: Compact search results and passage navigation
date: 2026-10-06
status: implemented
scope: macos-search-ui
---

# Problem

The People Matches scroll area reserved 176 points plus a count footer for one name. Result rows repeated metadata, exposed ranking diagnostics by default, and required opening a meeting before playback.

# Implemented solution

The header shows a result count, Search Mode, and optional Show Ranking Details. Unambiguous People matches use compact transcript-palette chips with overflow; Possible Matches expands separately and does not imply a ranking boost. Each reusable native row shows title, date, summary heading when available, source/time, two lines of passage text, Open, and Play for timed passages. Play starts the meeting at the passage timestamp without leaving results. Toolbar Back restores the retained query, selection, and pixel scroll offset. The search toolbar item has a stable identity, and native editing only resigns on an explicit focus-binding transition, preserving typed input while model loading updates the toolbar.

# Reasoning

The user-provided annotated screenshot and existing Preview capture establish the excessive gap. The design spends width on content and row actions, keeps passages individually ranked, and retains the native table's paging and keyboard behavior. Summary headings come from lightweight indexed metadata rather than loading complete meetings.

# Technical debt

No new shortcuts. The existing `ViewState` alias is retained because the Command Line Tools SDK exposes a SwiftUI State macro without its implementation plugin. It selects the supported property wrapper; remove this compatibility alias when all supported toolchains provide the macro. Existing search session storage and native cell reuse are retained.

# Validation

- `make build-macos` passed in the isolated `tmp/search-layout-validation` copy, signed with macOS 26 minimum and SDK 27. The logged 2,905-second duration includes laptop sleep and is not a build-performance measurement. The existing Command Line Tools linker warnings report missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths; no new deprecation warning was reported. Formatting, lint, and diff whitespace checks passed.
- Captured and inspected production Search Results in the unique `com.gdaymeetings.macos.searchlayoutpreview` bundle, revision `search-layout-20261006`, on macOS 26.6.2 with Swift 6.4. Synthetic fixtures and silent playback were enabled. Light and System-dark appearances show compact chips, count/mode controls, title/date/source/summary heading, and separate Open/Play actions.
- Manually installed the validated 97M FP32 package into this Preview's temporary library. Semantic search returned five individually ranked passages. Show Ranking Details exposed the expected content/speaker/bonus/final scores. A misspelled synthetic name appeared under Possible Matches, with zero bonus and an explanation that it does not affect ranking.
- Play started at the first result's 0:01 timestamp while Search Results stayed visible. Open selected the corresponding transcript passage. Toolbar Back restored the query and selection. After scrolling to the bottom, Return opened the selected last result and Command-[ restored the selected result and scrollbar position.
- Visual inspection found that truncation mode suppressed wrapping despite allocating two excerpt lines. Changed the excerpt to word wrapping; the combined release build passed in 97.93 seconds, and the updated mixed-FP16 Preview capture confirms two-line wrapping. The parent also verified downloading the new model through provider settings, semantic results, Play at 0:01, Open at the matching transcript row, and Back restoring the selected result.
- The final combined release passed in 95.47 seconds with the same existing linker-path warnings. Real-library semantic results, Open at a matching passage, and Back were checked in a separate validation bundle. The initial loading refresh had replaced the active search field; assigning a stable toolbar identity preserved the complete typed query and first responder through the Loading-to-Ready transition. The final result screenshot was inspected, and the validation app was closed.
- Chip overflow with many long names, the minimum window width, VoiceOver narration, and accessibility preference variants remain untested. The initial layout checks used synthetic data and silent playback; the final parent check used the authorized real library without starting a recording. Other running app copies were preserved. No commit or push was made, so CI was not run.
