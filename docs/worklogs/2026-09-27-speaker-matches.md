---
title: Treat recognized speakers as assigned people
date: 2026-09-27
status: implemented
scope: swift-speaker-recognition
---

## Problem

Automatically recognized people appeared as “Suggested” and required confirmation. Their meetings were missing from People associations, and Rust imports downgraded automatic assignments to suggestions.

## Implemented solution

Speaker names now display directly in transcripts, context, and exports. The Speakers panel retains Assign Person, Reassign, and Remove Assignment, without status badges or Confirm and Reject controls. Automatic recognition and Rust import link people to meetings. Opening an existing Swift library restores these associations without changing speaker snapshots used to resume transcription. Preview includes assigned, automatically matched, and unassigned speakers and a rich Markdown summary.

## Reasoning

A person ID is an assignment regardless of how it was obtained, matching Rust's recognition behavior. Explicit assignment still adds a voice sample; recognition alone does not train on its own prediction. Reassignment and removal continue to remove the previous sample atomically with the person link. Provider and embedding compatibility checks remain intact.

The parent agent captured and inspected the existing Preview Speakers panel before edits. The design keeps the same rows and assignment menus, removes both confirmation badges and the Confirm/Reject workflow, and displays names without qualification.

## Technical debt

The serialized `confirmed` field is retained solely for compatibility with older Swift clients, which require it when decoding the current library format. Assignment behavior no longer reads it. Remove this obsolete field in a future versioned library migration after older writers are excluded. Existing historical snapshots are left intact to preserve transcription conflict comparisons.

The existing People association model does not distinguish a manual meeting link from a speaker link to the same person. Removing that speaker assignment removes the overlapping association, as already happened for explicit speaker assignments. A future provenance-aware association model would preserve independently added links.

## Notes

Tests cover existing automatic matches on reopen, plain names in exported Markdown, unchanged voice samples, removal, Rust import associations, track-scoped matching, and explicit assignment persistence. The full suite passed 320 tests in 66 suites. Preview screenshots and accessibility inspection show ordinary assigned names, Reassign menus, and no confirmation badges or buttons at a narrow window width. The Reassign menu exposes Remove Assignment. Automatic approval review blocked clicking Remove Assignment even in the synthetic Preview; removal behavior is covered by the passing regression tests. No production assignment was changed. Real speaker recognition accuracy and hardware audio are outside this change.

Formatting, lint, and Preview build checks completed. Known Command Line Tools linker search-path warnings remain, as tracked in [the toolchain worklog](2026-09-25-swift-keychain-deprecations.md); no new deprecation warning was observed.
