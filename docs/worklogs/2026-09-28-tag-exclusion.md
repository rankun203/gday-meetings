---
title: Tag exclusion and person tags
date: 2026-09-28
status: complete
scope: swift-app
---

# Tag exclusion and person tags

## Problem

Tags could not hide associated meetings from the main list or search. People had no tag assignments.

## Implemented solution

- Add an **Excluded** checkbox beside the associated meeting count in tag details. Keep tags available for managing and reversing exclusion.
- Save person tag assignments and add tag chips and an Add Tag menu to person details. Hide people with an explicitly assigned excluded tag from People; **Show Excluded** reveals them for editing.
- Filter excluded meeting tags in indexed queries before pagination, search, and background prefetch. Cancel stale prefetch work when saved changes refresh the list.
- Keep direct tag and person context views available with their associated meetings. Exclusion is a browsing preference; it does not delete data, cancel jobs, change recording, or remove speaker assignments.
- Default older tag and person documents to included and untagged. Deleting a tag removes its person assignments as well as meeting assignments.
- Publish directory focus through SwiftUI focused values so the window playback shortcut leaves Space to focused directory controls.

## Reasoning

The existing tag detail screenshot has unused space to the right of its count. Place the independent on/off checkbox there without moving the meeting list. Use native controls and the existing tag chip layout for keyboard access and consistent spacing.

People are excluded only by their own tag assignments. Attending a meeting with an excluded tag does not automatically exclude a person. An excluded tag wins when an item also has included tags.

## Technical debt

The person tag row repeats the existing meeting tag chip presentation. This keeps the change separate from the meeting-specific new-tag sheet; future tag UI changes should extract a shared chip/menu component. Older clients ignore the new optional fields and may drop them when rewriting person or tag documents; avoid editing this metadata from older clients. A future library format upgrade should enforce reader/writer feature compatibility if mixed-version editing becomes supported.

## Validation

- Captured and inspected the existing synthetic tag detail in UI Preview before editing.
- Added tests for backward decoding, exclusion before paged search, reverse paging, associated counts, restart persistence, unexcluding, and tag deletion.
- The three exclusion tests passed. The full 430-test run reported two failures in the parameterized summary-streaming cancellation/truncation test while waiting for a transient draft; all six summary-streaming tests passed on an isolated rerun. The full-suite run was not clean.
- Formatting lint and diff whitespace checks passed. Release build and signing passed. The Command Line Tools linker still reports missing `Developer/Library/Frameworks` and `Developer/usr/lib` search paths; these are toolchain path warnings, not deprecated API warnings. No suppression was added. Follow up by validating the installed CLT/SwiftPM search paths or updating the toolchain.
- Preview confirmed person tag assignment, exclusion from Meetings and People, recovery with Show Excluded, and direct access through Tags. Captured the Excluded checkbox in the intended count row and the person tag chips. Inspected System/light and Dark appearance at large and narrower window sizes.
- Keyboard testing found the existing window Space monitor intercepted a focused tag menu whenever playback had a selection. The final build passed Tab-to-menu, Space-to-open, arrow/Return assignment, Shift-Tab-to-checkbox, and Space-to-toggle checks without starting playback. The native checkbox focus ring remained visible. Clearing exclusion restored the meeting list. The meeting-list Space playback shortcut still started and paused synthetic playback.
- VoiceOver speech, increased contrast, and older supported macOS versions were not exercised. These controls use native accessibility and semantic colors; no custom material or animation was added.
- The installed app and its recording were left running. Preview uses synthetic content and silent playback. No real recording or hardware playback test was performed.
