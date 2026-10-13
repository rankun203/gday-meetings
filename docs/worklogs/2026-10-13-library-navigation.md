---
title: Reveal navigation when leaving Meetings
date: 2026-10-13
status: implemented-with-validation-limits
scope: macos-library-navigation
---

## Problem

Opening Tasks or another destination while the sidebar was hidden left no visible route back to Meetings. Meeting tag chips treated their entire surface as removal, so clicking the name removed the association instead of opening the tag.

## Implemented solution

The library expands its native sidebar when navigation leaves Meetings, including Search Results. Returning to Meetings preserves the current sidebar visibility. Tag chips use separate native buttons: the name opens the selected tag, and the existing x symbol removes the association. The shared chip gives meeting and person tags consistent behavior. Tag navigation clears the tag-directory filter, reveals the target, and closes a containing meeting sheet or details popover.

Locally packaged `.app` bundles are ignored alongside existing build and temporary directories. The production bundle is staged separately from the installed app under ignored `tmp/production-20261013-navigation/`.

## Reasoning

Captured the existing production Preview with the sidebar hidden and Meeting Details open. The entire Preview and Planning chips exposed only a removal action. The design retains the single-row chips and native sidebar layout, separates navigation from removal, and changes sidebar visibility only when leaving Meetings. It adds no custom sidebar, alternate focus styling, timer, or event interception.

## Technical debt

None introduced. Existing sidebar transition-sizing and pointer-only validation limits are tracked in their own worklogs.

## Validation

- `make format-macos`, `make lint-macos`, and diff whitespace checks passed. The formatter also normalized three existing files; those formatting-only changes are committed separately.
- `make build-macos` passed in the isolated `tmp/sidebar-sizing-20261009` checkout. Production packaging, property-list validation, and signing completed. The build retains missing Command Line Tools `Developer/usr/lib` and `Developer/Library/Frameworks` linker search-path warnings; no deprecation warnings were emitted.
- Release tests passed: 20 tests in six sidebar, task-session, and transcript suites. The sidebar integration test now collapses the sidebar before changing to Tasks and checks that it expands and stays expanded on return.
- Full Preview used the new release executable with a separate bundle identifier and synthetic fixtures. A task-alert click opened Tasks and revealed the sidebar. Returning to Meetings retained the selected meeting. Activating the tag-name accessibility button opened the correct tag, closed Details, revealed the sidebar, and retained the meeting association. Returning to Meetings and activating × removed only the association, leaving the sidebar collapsed and Meetings selected. Captured and inspected the changed tag chips and Tags destination.
- Coordinate clicks on the tag name did not activate it through Computer Use; its native accessibility action did. Physical-pointer tag hit testing remains for the requested user trial. Person-tag and meeting-sheet routes share the implementation but were not separately exercised. The installed app and its recordings were not replaced, quit, or opened for validation.
- Logs: `/tmp/gday-navigation-release.log` and `/tmp/gday-navigation-tests.log`. Source: `7440a8f` plus the committed navigation, sidebar, filter, scrollbar, and formatting changes. Runtime: macOS 26.6.2, Swift 6.4, SDK 27.0; deployment minimum macOS 26.
