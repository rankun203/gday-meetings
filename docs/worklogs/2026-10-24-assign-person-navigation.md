---
title: Keyboard navigation in Assign Person
date: 2026-10-24
status: implemented
---

## Problem

Assign Person did not handle Up or Down in its search field. Enter always applied the first search result, with no visible candidate selection.

## User Intention

Use Up and Down to navigate the matching people while typing in Assign Person. Identify the recording speaker label in the popup, retain whole-speaker versus passage scope, and explain the actual reason for a dotted badge so a displayed person name is not mistaken for a unique recording speaker label. Preserve the running Test12 app and trial decisions.

## Implemented solution

The search field handles Up and Down, clamps movement at the first and last candidates, and keeps focus for further typing. The highlighted candidate scrolls into view and Enter applies it. Search changes reset to the first match; removed candidates fall back to the first current result. Empty results do not submit an assignment. Clicking a person still assigns immediately. The highlight has an accessibility selected trait. Assignment scope, creation, removal, passage restoration, save failure, and retry use the existing actions.

## Reasoning

The user's screenshot establishes the existing search-first popover and candidate layout. Keep those controls and native initial focus, following the earlier focus worklog. Add a subtle rounded highlight to the current candidate. Keyboard and mouse assignment use the same persistence action.

## Technical debt

None.

## Notes

Release build passed in the existing isolated checkout (macOS 26 minimum, SDK 27). Formatting, diff review, packaging, and signature checks passed. Existing Command Line Tools linker warnings for missing Developer/usr/lib and Developer/Library/Frameworks remain; no new deprecation warnings appeared.

Native synthetic checks verified the visible highlight, Down and Up, both boundaries, search focus retention, Enter applying the second candidate, filtering after navigation, no-op navigation/Enter with no matches, and Escape dismissal. The changed screenshot matches the planned search-first layout. Long-list scrolling, IME composition, and save-failure interactions were not exercised; persistence actions were unchanged. No new automated tests were added for this focused view change.

Test13 is packaged from base 027db65 plus the working-tree dialog fixes, identifying revision 027db65-assign-person-2c374f69. Its independent library carries the latest durable Test12 state for 20 completed meetings and 2,991 examples. Capture verified unchanged source files under a shared lock; tasks, jobs, Undo, and indexes were omitted. Remote providers and automatic processing remain disabled, and an independent baseline is retained. Native launch and runtime open-file checks verified the Test13 library with no Test12 library files open. Test12 and its data remain unchanged. Changes are uncommitted.


Test15 follow-up implemented: the popup identifies the recording label in its title and distinguish tentative identity, no assigned person, and unattributed words in grouped passages. A typed popup context captures displayed-passage uncertainty before the native table expands it and retains the canonical speaker-source row. The badge and popup share the dotted-state predicate. Six regression cases cover recording labels, distinct/simultaneous uncertainty reasons, nonfirst grouped targets, retained context, and source placeholders. Independent review found no remaining blockers; all six new cases passed in the integrated 86-test run. Test15 release build, formatting, and signature checks passed; revision is `027db65-test15-3faa058d`. Native screenshot/interaction verification was blocked by computer-use `cgWindowNotFound` for both the app and Finder. The running app and isolated library were verified through process/open-file checks. Earlier native keyboard evidence applies to Test13; new grouped-popup behavior is covered automatically and still needs a native trial. The supplied testing screenshots establish the existing ambiguity; keyboard selection, passage restoration, and assignment persistence must remain intact.
