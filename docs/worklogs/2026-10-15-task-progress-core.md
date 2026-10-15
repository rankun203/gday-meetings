---
title: Structured task progress and performance estimates
date: 2026-10-15
status: complete
updated: 2026-10-16
scope: macos-task-progress
---

## Problem

Background operations reported text without measured work, elapsed phase time, or reusable processing rates. Retried operations could receive delayed progress from a previous attempt.

## Implemented solution

Added a structured phase snapshot alongside existing task messages. Measured work supplies a fraction; phases without a known total remain indeterminate. Background updates coalesce within 500 milliseconds, publish phase changes immediately, and carry an attempt identifier. Queued, paused, and terminal journal transitions clear progress estimates.

Added a disposable performance cache beside the local index. Keys distinguish operation, provider, model, configuration, hardware, and OS without storing their raw identifiers. Successful processing phases explicitly record elapsed time and completed units. Estimates use the median of up to nine samples, expire after 30 days, and retain at most 128 keys. Serialized atomic writes run outside the main actor.

## Reasoning

Actual work determines progress. Time estimates never advance progress or complete tasks. Explicit sampling keeps preparation, queue waits, failures, cancellations, and recovered operations out of learned processing speeds. Existing journal records decode without the optional structured field.

## Technical debt

None. Operations without measurable work retain phase descriptions; unsupported totals are not inferred from time.

## Notes

Synthetic tests cover invalid totals, time-independent fractions, sample isolation and expiry, backward-compatible journal decoding, cleared paused estimates, callbacks from previous attempts, live progress during journal writes, and paging snapshots that precede terminal transitions. Release validation and UI inspection are coordinated by the parent task.

Final release, test, review, and UI results are recorded in the [parent worklog](2026-10-15-task-progress.md).
