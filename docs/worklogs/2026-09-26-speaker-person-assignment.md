---
title: Meeting tags and speaker assignments
date: 2026-09-26
status: complete
scope: swift-app
---

# Meeting tags and speaker assignments

## Problem

The Swift client grouped people and tags in a meeting header menu. Editing a speaker replaced its provider label with a name. RunPod voice vectors were discarded, so assigning a person could not help recognize that person in later meetings.

## Implemented solution

- Tags are editable meeting metadata. Multiple tags appear beside an Add Tag menu, with inline removal and creation.
- The Transcript tab contains a Speakers section after the transcript. Each provider label retains its track and result identity. Assign Person, New Person, Confirm, Reject, Reassign, and Remove Assignment manage person links without rewriting provider labels.
- RunPod results retain valid optional voice vectors with the saved result, including results held back because the transcript or speaker assignments changed during processing.
- Confirmed assignments retain local voice samples. Later results from the same RunPod endpoint suggest people using cosine similarity of sample centroids and the Rust client's 0.75 threshold. Suggestions remain unconfirmed; transcript display and exports identify them as suggested. A person can be suggested once per track, allowing the same voice on microphone and system audio.
- Reassignment removes the previous person's sample for that speaker. Rejecting or removing an assignment removes that sample. Repeated confirmation does not duplicate samples.
- Library version 2 retains speaker identities and samples. Version 1 is backed up before migration; old names become unassigned labels, without guessing a person identity.
- Voice recognition data has its own Data Privacy entry. Text exports and server archives omit vectors and samples. Text archive import removes foreign voice provenance and restores missing or stale speaker identities without guessing person links.
- Legacy saved transcription results gain speaker identities when applied. Rejecting an unconfirmed suggestion or replacing it preserves existing manual person associations.
- UI Preview includes three synthetic speaker states and two meeting tags, without submitting provider jobs.
- Rust library import preserves raw labels, tracks, assignments, and confidence. It migrates valid person samples into a separate legacy namespace. An imported match is confirmed only when the person’s sample has the same session and vector; confidence alone does not establish confirmation. Raw extraction tracks recover separate vectors when available.

## Reasoning

Tags describe a meeting. People identify voices in a transcript, so their assignment belongs with the provider's transcript result. Keeping IDs separate from display names preserves provenance, supports renaming people, and prevents same-label speakers on separate tracks from merging.

Only explicit assignments and confirmations train recognition. Automatic matches are suggestions, not verified identity. Matching rejects invalid or incompatible vectors and never creates voice data from text labels.

## Technical debt

RunPod's current worker response does not declare its embedding model or version. Samples are therefore restricted to the same configured endpoint and vector dimension. If a deployment changes its embedding model without changing its endpoint, same-dimension samples may become incompatible. Add embedding model/version metadata to the worker contract and migrate scopes before supporting comparison across endpoints. Imported Rust samples use a separate legacy namespace and are not compared with new RunPod output without compatible provenance.

Rust’s text-only confirmation action leaves no durable confirmation marker. Imported names without a matching confirmed voice sample remain suggestions, so the user can review and confirm them. A future Rust format should persist explicit attribution status; no inferred identity is substituted during migration.

## Validation

- 25 focused tests passed across speaker recognition, Rust import, meeting storage, and language handling. They cover track-scoped identity, invalid vectors, confirmation/reassignment/rejection, endpoint and dimension matching, migration backups, edit-conflict recovery, text exports, person deletion, local-only voice data, and persistence after restart.
- Source Rust files remain unchanged during import. Duplicate labels on different tracks retain independent speaker IDs. Imported voice vectors never match current RunPod output automatically.
- Final focused validation passed 14 tests across speaker recognition, legacy import, and library format. Additional checks cover failed-save rollback of the assignment and voice sample together, text archive reimport, and rejection of newer library formats. `git diff --check` passed.
- The test link step retained the existing Command Line Tools warnings for missing `Developer/usr/lib` and `Developer/Library/Frameworks` search paths. No Swift source or deprecation warnings appeared. These are toolchain paths; update the installed Command Line Tools or select a complete supported Xcode toolchain when available, then rerun the tests.
- After review fixes, 13 focused speaker and legacy-import tests passed. Old pending results regain speaker identities, stale imported IDs are repaired, and rejecting suggestions preserves manual associations. Malformed optional Rust voice samples or extraction files no longer prevent importing text and profiles.
- No real meeting audio was uploaded for this feature.

UI Preview checks passed for tag creation/removal, confirmation updating transcript names, and New Person assignment.

Final integrated validation passed all 217 tests in 43 suites, formatting, lint, and diff checks. Known Command Line Tools linker search-path warnings remain; no deprecation warnings were reported.
