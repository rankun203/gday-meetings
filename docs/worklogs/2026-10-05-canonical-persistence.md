---
title: Canonical persistence without blocking the interface
date: 2026-10-05
status: implemented
scope: macos-persistence
---

# Canonical persistence without blocking the interface

## Problem

Meeting, people, tag, and contextual-chat saves performed conflict checks, file transactions, receipts, and index updates on the main actor. Turning these into asynchronous operations also requires preserving newer edits, deletion ordering, and quit boundaries.

## Implemented solution

- A main-actor command queue admits durable saves in order. Each command captures immutable library values and runs its transaction on a background worker. Callers await the durable result; cancelling a caller does not abandon an admitted transaction.
- Successful completion advances the saved baseline without replacing newer in-memory edits. Failed writes roll back only values still owned by the captured command, using mutation revisions to detect changes that return to an earlier value. An unsuccessful transaction restore stops further writes and asks the person to reopen the library for recovery.
- Voice changes staged with a canonical transaction use an independent persistence worker and transfer only immutable document and revision state. Other voice writes cannot interfere with a staged transaction.
- Deletion reserves the meeting, drains preceding canonical writes, flushes notes, and moves the folder off the main actor. Notes remain reserved until deletion finishes. An index failure after moving the folder does not recreate the meeting.
- Cold meeting loading is explicit and asynchronous. The model getter only reads memory. Concurrent consumers share one worker read, and cancelling one consumer does not cancel the others. Generation and request tokens prevent late reads from publishing after library changes, deletion, or an invalidating filesystem event.
- Quit freezes new task and UI actions, stops active work, and drains task, canonical, and notes writes before returning. An aborted quit resumes task recovery. Changing libraries drains admitted saves before copying or opening another root. The drain waits for pending work; it does not re-report every previously completed and rolled-back UI save failure, whose result stays with its caller.
- Save-dependent UI, task, import, transcript, and synthetic preview callers now await the corresponding durable operation. The save path refreshes its visible meeting page on a worker.

## Reasoning

Canonical file writes require immediate consistency at the command boundary: downstream work must receive a committed result. Interface rendering and newer local edits can continue while the command waits for storage. Index and monitor refreshes remain derived state. AppKit and observable models stay on the main actor; moving shared mutable persistence objects into detached tasks would introduce races.

## Validation

CanonicalPersistenceTests passed, covering delayed storage, command ordering, caller cancellation, newer edits during a write, write failure, external disk conflicts, deletion behind an admitted save, pending notes at quit, and concurrent cold consumers with independent cancellation. The consolidated run executed 217 tests across 34 suites without compiler warnings. All persistence, notes, history, chat, voice/people, paging, playback, and summary checks passed; one task-recovery fixture still assumed immediate store deallocation instead of awaiting the quit boundary. Both recovery fixtures now await the quit boundary. The affected ManagedTaskTests, ManagedTaskRecoveryTests, and CanonicalPersistenceTests rerun passed all 28 tests in 0.953 seconds without warnings. Subsequent combined release validation is recorded below.

A person-merge fixture exposed the new asynchronous voice-reconciliation boundary. Voice refreshes now have a tracked serial task and an explicit drain; quit waits for them, and the fixture awaits reconciliation before installing its synthetic projection. Library switching waits until reconciliation finishes.

The combined `40e64af-async-review` release passed in 162.70 seconds without compiler warnings and passed platform/signature checks. Synthetic Preview validation confirmed notes persistence across immediate navigation; the installed app was preserved. At this validation checkpoint, no push or remote CI run had been performed.

## Technical debt

Existing independent paths remain outside this transaction migration: transcript-history preservation, ordinary voice-library commands, import/audio preparation, initial library setup, and some indexed paging queries still perform synchronous work. They can still contribute to interface latency. Ordinary voice commands currently return a busy failure while a staged canonical voice commit is pending; they cannot share the worker’s revision state safely. A future unified asynchronous voice-command queue should let those commands wait rather than fail, including background preparation results. Transcript-history loading was migrated separately during this task. The remaining paths require their own ownership and durability boundaries; the follow-up is to measure them and migrate the remaining storage operations without weakening history or voice transactions. This work adds no schema or compatibility bridge.

Precommit UI review added a recording-identity check after the language update awaits durable storage. A delayed completion can update the intended meeting's language, but changes the live recognizer only while that same meeting is still recording. This preserves the control's existing behavior across the new suspension point.
