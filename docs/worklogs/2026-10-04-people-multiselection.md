---
title: Merge selected people from one action row
date: 2026-10-04
status: complete
scope: swift-people-library
---

## Problem

Merge occupied a separate row and the People list accepted only one selection. Selecting duplicates together was not possible.

## Design and evidence

Inspected the supplied screenshot and captured the existing People screen in isolated Preview before editing. Put **Review Voices…** and **Merge…** in one compact native action row. Show Merge only for two or more selected people. Use native list multiple selection, including Command-click and Shift-click. Show a selection count in the detail pane for multiple people. The merge sheet lists only the selected people and asks which person to keep. Cancel preserves the selection; success selects the retained person. Remove the single-person context-menu merge action.

## Implemented solution

- The People selection is a set shared with the library detail pane. Filtering or deleting people removes hidden or missing IDs from that selection.
- The merge sheet captures the selected IDs and previews their combined details. Its commit requires every selected person to still exist and the retained person to belong to that selection.
- The store merges all selected sources in one existing file transaction and one metadata scan. Voice references and chats transfer together; unrelated contacts remain unchanged.

## Reasoning

Choosing duplicates in the list matches native macOS selection behavior and avoids asking users to find the second person again. Generalizing the transaction preserves all-or-nothing behavior for selections larger than two; repeatedly committing pairwise merges would allow partial completion.

## Technical debt

No new schema or compatibility bridge. Retains the synchronous metadata scan and file transaction described in the original merge worklog; large libraries may pause the UI. A serialized background writer with progress remains the concrete follow-up before claiming large-library responsiveness.

## Validation

- The six focused merge tests passed in 0.982 seconds, including both successful and failed three-person transactions, rejection of an unselected retained person, preservation of unrelated contacts, and all earlier pairwise regression cases.
- Formatting, lint, and diff whitespace checks passed. The final release build passed in 100.64 seconds, including plist and signature checks. Existing Command Line Tools linker warnings for missing Developer library/framework search paths remain; no deprecation warnings appeared. Repair or update the local developer tools to resolve those paths.
- The first Preview run exposed a sheet-opening race between two separate state values. An item-driven sheet now carries one immutable selection request; the final run verified that the first opening receives the correct IDs.
- Captured and inspected the action row in light and dark appearance. Verified no Merge action for zero or one selected person, Shift-arrow multiple selection, Command-A selection of three synthetic people, two- and three-person sheet contents, retained-person preview, Escape preserving selection, and filtering clearing hidden selections. Search and list content retain their vertical positions when Merge appears. Restored Preview’s original Light preference.
- Used the exact `.build/preview/Gday Meetings UI Preview.app` from revision `99b99fe` plus these changes on macOS 26.6.2, Swift 6.4, arm64. Real contacts and the installed app remain untouched. No UI merge was committed; the automated tests cover commit and rollback. Command-click, narrow-window, VoiceOver, System appearance, and older-macOS checks were not performed.
- Commit and push continue the user’s earlier publication instruction. Check the macOS CI matrix after pushing.
