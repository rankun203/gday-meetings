---
title: People voice review notice
date: 2026-10-14
status: complete
scope: macos-people
---

## Problem

Pending voices were discoverable only through the People Actions menu. The user-supplied screenshot shows the existing People toolbar, menu, and two content columns; it is the baseline evidence for this change.

## Implemented solution

- Place a compact review bar below the People toolbar, above both content columns and outside the sidebar. Show the pending voice count on the left, with **Review Voices…** and an icon-only dismiss button on the right. Use a standard bordered action, a subtle system bar background, and a separator.
- Count distinct voice groups using the review sheet’s existing `needsReview` eligibility. Open the same review sheet from the bar and People Actions menu.
- Remember dismissed example identities in preferences scoped to the library’s standardized URL. Removing reviewed examples does not reopen the notice; a new pending example does, even within an existing voice group. Dismissal changes no review decisions, and a completed queue hides the notice.

## Reasoning

The [Apple Photos guide](https://support.apple.com/en-lb/guide/photos/phtad9d981ab/mac), reviewed October 14, 2026, describes reviewing suggestions, accepting or rejecting them, and finishing with Done. The existing voice review sheet already provides an explicit review workflow. The new bar makes that workflow discoverable without changing voice assignments automatically. Apple’s guide does not specify this exact bar layout; the layout follows the user-approved design.

Batch dismissal uses example identities rather than counts so a replacement or an added example can surface even when the displayed voice count stays the same. Only the most recently dismissed pending batch is stored. Preference state is separate from voice evidence and its database schema.

## Technical debt

None.

## Notes

- Source: `VoiceReviewNotice`, `PeopleVoiceReviewBar`, `LibraryView`, `PeopleView`, and `VoiceLibraryStore`.
- Added tests cover dismissal across instances, library isolation, a shrinking or empty batch, new examples in an existing group, replacement at the same count, and review eligibility.
- Baseline inspection used the user’s captured screenshot. Computer Use initially failed to start; a later retry succeeded. Captured the changed synthetic People screen and verified the bar spans both content columns, outside the sidebar. Its review button opened the six-group review sheet; Done returned to People; dismiss removed the bar; People Actions still opened the same six-group sheet. No real library or recording was modified. Dark appearance, narrow window layout, and VoiceOver narration were not separately exercised.
- Validation passed: 3 notice tests and 36 existing voice-library, fragment-review, conflict, and startup tests; `make lint-macos`; and `git diff --check`. Test logs are `/private/tmp/gday-voice-review-notice-tests.log` and `/private/tmp/gday-voice-review-regression-tests.log`.
- Isolated `make build-macos` passed, including signing and platform verification (macOS 26.0 minimum, SDK 27.0). Log: `/private/tmp/gday-people-review-release.log`. A synthetic test app is available at `tmp/Gday Meetings People Review.app`.
- The test and release builds reported existing Command Line Tools linker warnings for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search directories. No deprecation warnings were reported.
