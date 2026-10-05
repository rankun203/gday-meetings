---
title: Totals at the end of app listings
date: 2026-10-05
status: implemented
scope: swift-list-ui
---

## Problem

The end of the meeting list had no total. The number of loaded rows cannot provide that total because the list pages and trims its in-memory window.

## Evidence and design

Captured the bottom of the two-meeting synthetic library before editing using `apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`, labeled `40e64af-responsiveness-ui`, on macOS 26.6.2. There was empty space after the last row with no count. The capture is in the task's computer-use output.

Show a centered secondary-text footer, such as “2 Meetings,” after the final meeting. It scrolls with the list and cannot be selected or activate meeting actions. It appears only after pagination reaches the end, not at temporary page boundaries. Empty libraries retain their existing empty state.

## Implemented solution

`LibraryView` asynchronously requests the indexed total after reaching the list end. Request identity includes the index revision, current query, excluded tags, and visible meeting identities; obsolete results cannot replace the current count. `LibraryIndex.count` now accepts the same literal query used by meeting pagination. No meeting content or folders are scanned for the footer.

`NativeMeetingList` renders an optional nonselectable trailing count row. Other callers omit the count and retain their existing layout. Selection, context menus, deletion, playback, and viewport callbacks continue to operate only on meeting rows.

### Expanded listing scope

The user subsequently requested the same treatment for all substantive listings. Before editing these screens, captured the People, Tags, associated meetings, Tasks, voice groups/examples, Service Providers, and Search Results screens in the `40e64af-sidebar-review` synthetic Preview. People and Tags had fixed totals separate from their scroll content; associated meetings and search had header totals; Tasks had an operational status summary; voice review and providers had no totals. The design places a quiet count after the final row, preserves existing filters and empty states, and keeps operational summaries distinct from collection totals.

| Listing | Count source and end condition |
| --- | --- |
| Meetings | Detached indexed query with current exclusion/query filters; final page only. |
| People and Tags | Existing `DirectoryPaging.total` for current query/exclusions; no next page, loading, or error. Replaces fixed bottom totals. |
| Associated meetings | Existing indexed associated-page total; no older page, loading, or error. |
| Tasks | Complete cached indexed state counts plus matching preview tasks and voice jobs for the selected scope; no older page, loading, or journal error. |
| Search Results | Full text-match total after pagination. Ranked search reports “Results Shown” to avoid presenting a bounded result set as all matches. |
| Voice review | Filtered voice-group count and selected group's example count from existing hydrated arrays. |
| Service Providers | Configured providers plus the two built-in providers shown in the list. |
| Data Privacy | File/action/destination groups, not the sum of event counts that can repeat across groups. |
| Speaker Labeling History | Loaded history entries, qualified as entries shown when history is incomplete. |

`ListCountFooter` and `NativeListCountCell` share caption typography, secondary text, and a centered trailing layout. Native footers are nonselectable; SwiftUI list footers use Apple's supported `selectionDisabled()` modifier. Search double-click activation now checks the clicked row so a footer double-click cannot open the previously selected result. Agents displays a Markdown document and has no collection count. Transcript, notes, chat content, settings forms, menus, and assignment/merge pickers are outside collection-footer scope.

## Reasoning

An indexed total remains accurate beyond the retained page window. Keeping the count request outside view evaluation and off the main actor avoids blocking interaction on SQLite. Showing it at the actual end avoids presenting a loaded-page count as the library total. A failed count read leaves the footer absent instead of showing an incorrect number.

## Technical debt

None.

## Validation

Added a synthetic regression for counts beyond the first page, excluded tags, literal query matches, combined person and tag filtering, and no results. All 11 `MeetingPagingTests` passed with Xcode 27; the debug build reported no compiler warnings. The first restricted-sandbox attempt could not launch the manifest compiler (`sandbox_apply`); the permitted retry completed. Owned Swift files were formatted and `git diff --check` passed.

The parent task completed the integrated release build in 150.76 seconds with no warnings and passed formatting/lint. Launched the exact Preview bundle above, now labeled `40e64af-sidebar-review`. Dark and light screenshots show “2 Meetings” centered after the two synthetic meetings. Clicking and double-clicking the footer retained the selected meeting and paused playback. Down Arrow at the last meeting did not select the footer; Up Arrow selected the preceding meeting. The count is exposed as text in the accessibility tree. Screenshots and interaction observations are in the task's computer-use output.

Visual checks used the short two-meeting fixture; large-library pagination and filter totals were covered by the index regression, not a long scrolling UI run. VoiceOver and increased-contrast settings were not exercised. Preview was handed to the sidebar/transcript reviewer for the remaining integrated checks.

Expanded-scope focused validation passed: 35 tests across `DirectoryPagingTests`, `ManagedTaskPagingTests`, `MeetingPagingTests`, and `AssociatedMeetingPageTests`; Xcode emitted no compiler warnings. Added regressions for directory footer visibility at page boundaries and after filtering, and for task totals that exceed the retained task records while including preview extras exactly once. Checked Apple's current [`selectionDisabled(_:)` documentation](https://developer.apple.com/documentation/swiftui/view/selectiondisabled(_:)) before using it for SwiftUI footer rows.

The privacy/history reviewer captured the privacy list bottom before adding its group footer. The current synthetic history screen remained in its existing loading state during baseline inspection; the reviewer also inspected the earlier synthetic populated history capture at `tmp/native-window-polish-2026-10-05/history-baseline/labelings.png`. The history footer counts entries shown, including a known empty history, but remains absent while loading. At that checkpoint, expanded release and visual validation awaited the combined persistence changes; subsequent results are recorded below.

The reviewer checked release Preview `40e64af-async-review`: screenshots showed “2 Meetings,” “2 People,” “2 Tags,” and “20 Groups” in Data Privacy. Service Providers exposed “2 Providers” in the accessibility tree; no screenshot is claimed for that check. Empty Tasks retained its existing empty state. Speaker Labeling History still showed “Loading History”; review traced this to an asynchronous value captured by the popover. The view now observes that value through a binding, with no loader or ordering change. The final release and visual-check outcome are recorded below.

The final combined release passed in 176.24 seconds without compiler warnings or errors and includes the history binding correction. The first final popover visual verification attempt was blocked: the UI tool could not obtain the synthetic Preview window, so no successful post-correction history display is claimed. Prior footer screenshots and automated count tests remain the available evidence.

The October 6 retry succeeded in release Preview `40e64af-people-persistence-review`. Speaker Labeling History displayed the saved synthetic analysis and exposed “1 Entry Shown,” confirming that the binding correction leaves the loading state. People and search screenshots also showed the filtered “1 Person” count and content-result totals; the two-meeting footer remained below its rows. The earlier screenshot and keyboard-selection checks still apply. This retry did not repeat every long-list or accessibility configuration.
