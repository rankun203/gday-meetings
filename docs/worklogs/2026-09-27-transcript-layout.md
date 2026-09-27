---
title: Compact meeting and transcript layout
date: 2026-09-27
status: implemented
scope: macos-transcript-ui
---

## Problem

The recording detail reserved a flexible 230–330-point frame around an intrinsic card, creating empty space above and below it. Transcript rows placed text below the timestamp and speaker, and suggested names included a redundant suffix.

## Design before implementation

Reviewed the supplied recording-gap and transcript-row screenshots. Lay out the smaller editable title, intrinsic recording card, and tabs from top to bottom with consistent spacing. Only the content viewport receives remaining height; expanded recording settings keep a bounded scroll viewport. Preserve horizontal padding.

Place timestamps, speaker names, and wrapping editable text on one top-aligned row. Right-align timestamps in a shared hour-capable gutter so hour digits expand left. Reserve a wrapping speaker column only when the transcript contains speakers. Keep recognition confirmation in Speakers, without a suggestion suffix in row names. Preserve timestamp seeking and native editing.

## Implemented solution

Removed the recording-only geometry and flexible outer card frame. The title uses the system title2 font, the vertical stack uses 12-point spacing, and expanded settings alone use a 100-point scroll viewport. TranscriptRow shares an hour-capable timestamp gutter, an optional 100-point wrapping speaker column, and multiline editable text. Row display suppresses the suggestion suffix while the default speaker-name API and confirmation data remain unchanged.

Added boundary checks for minute/hour formatting and a `--transcript-layout` Preview fixture with long text, a long speaker name, and adjacent 59:59/01:00:00 rows. The integrated 308-test suite, formatting, lint, and production build passed. Compact title/card spacing, long-name row wrapping, hour-column alignment, and title editing have not been visually checked in this revision. The user is interacting with the validation app, so those checks are deferred without closing it.

## Reasoning

Intrinsic sizing removes the blank space without manipulating scroll offsets or adding animation. Shared columns preserve alignment across minute and hour timestamps and long speaker names.

## Technical debt

None identified. Final visual checks pending.
