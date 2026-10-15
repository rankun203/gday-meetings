---
title: Recording save conflicts
date: 2026-10-15
status: complete
updated: 2026-10-16
scope: macos-recording-persistence
---

## Problem

Recording start and completion used a whole-library save. A conflict in another loaded meeting could stop a new recording from being saved. Completion rejected independent changes to the recording’s metadata, and a failed save could roll finalized duration and profile back in memory. Notes saved independently could also leave a meeting ineligible for metadata reload.

## Implemented solution

Recording creation, metadata finalization, conversion, live adoption, and finalization receipts save the affected meeting. These saves flush only that meeting’s notes. Ordinary capture saves do not commit pending voice changes; live adoption explicitly retains its existing voice transaction.

A three-way comparison preserves independent disk edits and rejects incompatible changes to the same information. Audio files and their profile, and transcript and speaker metadata, are treated as related information. The committed meeting becomes the saved baseline. Edits made locally while the worker runs remain in memory alongside unrelated committed disk fields.

Finalization writes a recovery proposal and baseline before committing metadata. On a later meeting load, recovery retries only a compatible merge and keeps the record when a conflict remains. Read-only libraries do not run recovery writes. A failed conversion restores references to the original files before deleting incomplete converted outputs.

Metadata reload now tolerates notes-only differences after the independent notes writer has saved them; pending notes still prevent reload.

## Reasoning

The active recording owns its capture result, but that does not make every other field in its earlier meeting snapshot newer than disk. Scoped commands and explicit reconciliation preserve capture results without replacing unrelated work or letting unrelated meeting conflicts block recording.

## Technical debt

Recovery restores finalized metadata but does not automatically resume a blocked processing pipeline. A capture failure may have accompanied the metadata failure, and the existing task record does not distinguish those outcomes sufficiently to authorize automatic processing. The recording and recovery proposal remain available. A follow-up should persist capture and metadata outcomes separately and provide a specific finalization retry action that resumes dependencies only after both outcomes are valid.

The existing cross-process transaction protocol is unchanged. These changes reconcile and recheck disk state within that protocol; they do not introduce a cross-process writer lease.

## Validation

Synthetic regression tests cover independent disk edits, competing capture changes, live transcript and notes preservation, derived person identifiers, existing-folder collisions, unrelated dirty meetings, saved notes reload, read-only recovery, later local edits, and retained recovery metadata. The recording persistence, canonical persistence, pipeline, live adoption, and library-folder regression suites passed. The isolated release build passed with existing Command Line Tools linker search-path warnings. Stopping synthetic recording saved the duration and changed Notes to Read without a disk-conflict dialog. No main-library files or installed-app state were changed.

The [integrated commit review](2026-10-16-repository-commit-review.md) records the final full-suite and release validation.
