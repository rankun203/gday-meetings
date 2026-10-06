---
title: Library toolbar actions
date: 2026-10-06
status: complete
scope: swift-app-ui
---

# Library toolbar actions

## Problem

Add Meeting appeared beside detail tabs, away from the Meetings list. Empty selection offered no action. File and Recording used different import names and recording behavior from the toolbar.

## Implemented solution

Scope Add Meeting to the native leading list toolbar, beside Meetings, with media import followed by notes. Keep Record immediately before native Search and retain detail content tabs. Give empty selection a recording action; place empty-library creation actions vertically in the detail pane. Share the notes action with File, open new notes in Notes, and open recording setup from both File and Recording. Keep archive import, library migration, and folder access in File. Recording status uses distinct starting, active, and saving labels.

## Reasoning

The prechange synthetic Preview showed Add beside the detail tabs while the Meetings title sat far to its left. The design separates list creation, selected-meeting content navigation, and global Record/Search. Preview showed that automatic and primary placements still merged Add into the trailing group; native navigation placement correctly keeps it beside the list title with the sidebar hidden or shown. No custom offsets or toolbar replacement were needed.

The initial empty-library layout clipped its heading and horizontal actions in the list column. The final version keeps a compact No Meetings message in the list and offers Create a Meeting with stacked actions in detail. Preserve the existing 900-point window minimum; native search minimization and overflow handle constrained toolbar space.

Reviewed Apple’s [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview), and [navigation placement](https://developer.apple.com/documentation/swiftui/toolbaritemplacement/navigation) guidance on October 6, 2026. Existing transcript and summary actions remain scoped to their content views. The menu-bar extra retains its existing distinct quick-start command and Option-key setup alternative.

## Technical debt

None added. The existing SDK-conditional recording visibility priority remains: Swift 6.4 exposes an API back-deployed to macOS 26.1; older compilers keep native default priority. Remove that compiler branch when the repository requires Swift 6.4. This compatibility path does not change action behavior.

## Validation

- `make format-macos`, `make lint-macos`, and `git diff --check` pass.
- Final `make build-macos` passes in isolated `tmp/toolbar-review/checkout`; linked minimum macOS 26.0, SDK 27.0, signing verification passes. Final log: `tmp/toolbar-review/verified-release-build.log`. Build warnings remain for absent Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` search directories. The first relocated build also warned about stale cache paths. No deprecation warning appeared. No push or CI run was requested.
- Preview verified Add beside Meetings, Record before Search, no-selection state, and selected-meeting tabs at 1200- and 900-point widths. With the sidebar expanded at 900 points, Search minimizes; Command-F and the Search button expand it. Native overflow retains Record while other controls yield space.
- Add and File both create notes and open Notes. Command-N and Command-Shift-R open recording setup; cancellation preserves the existing library. Menu names/order and recording-time disabled media import were inspected.
- Final empty-library actions fit at 900 points in dark appearance; creating notes from that state succeeds. Light and dark native appearances were inspected. Synthetic active recording remains visible while browsing another meeting; toolbar Show Recording returns to it without stopping, and Stop & Save returns the toolbar to New Recording.
- Selection regression validation is recorded separately in the selection worklog. Its eight focused tests and cold-record Preview checks passed against the combined release source.

Evidence is under ignored `tmp/toolbar-review/` and the tool transcript. Baseline: root Preview revision label `0933d7b-clsp-final`, ordinary fixtures, light appearance, 1109 × 680-point window. Final source: `307510b` plus the toolbar diff saved as `source-final.diff`. Final bundles are `Verified Preview.app` (ordinary fixtures) and `Recording Preview.app` (`GdaySyntheticLiveRecording`), built from the isolated release; `Leading Preview.app` used chrome-only mode for toolbar/size checks and has the same final toolbar code. Captures include `before.png`, `no-selection-wide.png`, `narrow-sidebar.png`, `narrow-search.png`, and `empty-dark-narrow.png`. Environment: macOS 26.6.2, Swift 6.4; captures October 6, 2026.

Limits: real capture, permissions, hardware playback, VoiceOver speech, Reduce Motion, Reduce Transparency, increased contrast, macOS 26.0 runtime, and sustained startup/finalization states were not exercised. Preview never accessed the production library or Keychain, and no provider job was started. Starting/saving labels and disabled rules were reviewed in code; the synthetic stop transition completed too quickly to inspect the saving frame.
