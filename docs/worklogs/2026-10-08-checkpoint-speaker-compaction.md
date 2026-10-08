---
title: Compact unused speaker checkpoint history
date: 2026-10-08
status: focused validation passed
scope: live transcript checkpoint persistence
---

# Checkpoint speaker history

## Problem

Repeated labeling resets allocate eight identities per generation. Pruning the live attribution window does not prune the separately saved checkpoint metadata. Unused allocations and retired generation identifiers can therefore dominate the checkpoint even when few identities appear in the transcript.

## Implemented solution

`LiveCheckpointSpeakerHistory` retains metadata reachable from committed transcript rows, recent rows, manual correction anchors, and identity aliases. It also preserves person associations, explicit manual unassignments, review cutoffs, and retained embeddings, including evidence without a transcript row. An unfinished checkpoint retains the latest source namespaces. Retired generation identifiers are retained only when associated with retained speaker metadata or current source cursors.

The projection storage actor tracks speaker IDs in successfully committed rows. Appends extend that set; a correction that rewrites rows rebuilds it. The set advances only after the checkpoint commit succeeds. Compaction runs on this storage actor, not the UI actor.

Checkpoint version 2 and the meanings of `bytes`, `rows`, `segments`, and `finished` are unchanged. Source-placeholder semantics and unique speaker UUIDs are unchanged. The loading task's commit-only decoder remains in place. Gap records and the separate speaker-evidence journal are untouched.

This affects future checkpoint writes only. It does not migrate or rewrite existing finalized meetings during startup, opening, indexing, or validation. Tests use disposable synthetic directories; UI validation uses a separate library copy.

## Reasoning

Retention follows useful references and evidence rather than a fixed speaker count. A fixed cap could discard a real participant, a user correction, or evidence needed for review. Historical checkpoint size can still grow with actual transcript identities, voice evidence, and gaps; empty channel allocation alone no longer requires retaining every generation.

## Validation

The final focused integration run passed 80 native tests across 14 suites in 2.716 seconds in an isolated full app package, including all 16 checkpoint-compaction and saved-transcript tests. The three shared compaction files match the tested copies byte for byte. Full integrated app validation remains pending. Tests cover a synthetic history of 128,000 allocated identities with 29 referenced identities; alias chains and cycles; explicit unassignment and embedding preservation; current namespaces; incremental writes and finalization; ordinary transcript loading and recovery; unchanged commit boundaries; and an untouched evidence journal. Existing interrupted-append and correction-rewrite tests run alongside these cases.

## Technical debt

None added. Existing finalized checkpoints are deliberately not migrated by this change. A future explicit maintenance operation would need its own backup, validation, and user-visible scope; ordinary loading must not rewrite them incidentally.
