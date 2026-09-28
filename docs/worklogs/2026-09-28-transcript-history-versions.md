---
title: Transcript versions and provider labels
date: 2026-09-28
status: validating
scope: swift-transcript-history
---

# Transcript versions and provider labels

## Problem

History used “Previous Transcript” and the time an old transcript was archived, rather than its provider and generation time. Selecting an earlier transcript could archive another copy each time, making switching look like new transcription work.

## Implemented solution

Transcript source metadata contains a stable version ID, provider name, and generation time. Provider completions derive the version ID from the request's stable idempotency UUID. Live transcripts use the recording's first speech-session identity and saved checkpoint time. Selecting a version does not create a new identity or timestamp.

Revision storage upserts the current version by ID before replacement. Selecting another version restores its transcript, speaker associations, and source metadata. Edits belong to the selected version and are saved into that version on switching. The menu merges archived versions with the current version, replacing any older snapshot of the same ID; the current choice shows a checkmark. Labels use the provider and generation timestamp. The live choice no longer says “Restore Live Transcript.”

Imported or manually supplied text can legitimately have no provider metadata. Such a version uses a neutral **Transcript** label, never a guessed provider. Its stable initial identity is the meeting ID. No app migration or duplicate cleanup bridge was added for existing development revisions.

## Reasoning

Actual transcription requests define versions. Restoring or editing text does not run a provider and must not create another generation. Keeping the current transcript authoritative in its existing files avoids writing an extra revision snapshot on every keystroke; upserting before switching retains those edits.

## Validation

Inspected the supplied open history-menu screenshot before implementation. Focused regressions exercise repeated A–B switching with a constant choice count, edited text restored on return, a third generation with identical text, and repeated live selection retaining its source. Parent agent will inspect the rebuilt menu and run consolidated validation.

Parent review found that identical text from a provider and the live checkpoint could skip a requested version switch. The live adoption fast path now also compares source identity; its regression passes. The consolidated suite passed all 418 tests across 83 suites. Preview now labels its synthetic provider result explicitly so the history menu can be checked against its live version.

Rebuilt Preview visual validation passed: switching between This Mac and Preview Transcription retained exactly two entries, moved the current checkmark, and restored the selected text and speaker labels. The menu showed provider names and generation times without “Previous Transcript.”

## Technical debt

Existing development revisions without recorded provider provenance retain a neutral label; their original provider cannot be reconstructed reliably from this metadata. A separate temporary migration can repair records when independent evidence exists. No runtime compatibility path was added. Live identity is tied to the first saved speech session; introducing multiple distinct recording generations inside one meeting would require an explicit checkpoint generation identifier.
