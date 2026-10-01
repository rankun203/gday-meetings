---
title: Data Privacy event groups and destination identities
date: 2026-10-01
status: complete
scope: swift-app
---

# Data Privacy event groups and destination identities

## Problem

Frequent live transcript saves produced repetitive rows in Data Privacy. Receipts stored provider names without IDs, so renames and duplicate names could not be resolved reliably. File descriptions mixed paths with explanatory text.

## Implemented solution

New receipts store the provider UUID or the built-in This Mac UUID and explicit meeting-relative file paths. The recorded name remains a historical fallback. Data Privacy resolves current names from a dictionary keyed by UUID and groups receipts by file, action, and destination, preserving the recorded domain and location.

Collapsed rows show the file, action, destination, event count, and latest time. Expanding a group shows its receipts; expanding a receipt shows timing, sizes, contents, and destination ID. Group expansion uses stable keys during history refreshes. Multi-file receipts appear under each referenced file; byte counts remain receipt-wide and are not summed as file totals.

## Reasoning

The supplied screenshot and an unchanged isolated preview showed repeated three-line receipt rows. The design retains the existing disclosure interaction and quiet surface while placing the file first. Grouping changes presentation only: the append-only journal retains individual receipts. New identities must be supplied by the producer; names are never used to select a current provider.

## Technical debt

Legacy receipts have no destination ID or structured file references. A compatibility group recognizes the complete old local saved-file receipt shape; it stays separate from UUID-bearing receipts. Other unidentified legacy destinations remain separate because shared names do not prove shared identity. Preserve the journal without rewriting history or guessing provider identities. The journal still reloads its complete history after file changes; incremental reading remains a follow-up for very long histories.

## Validation

Before-edit and changed screenshots were inspected in the isolated synthetic preview. Twelve synthetic transcript saves collapse to one row; a separate Created action stays separate. Group and receipt disclosures expose destination IDs, timing, and total request/response sizes. System (light) and Dark appearances were inspected. Tab reaches the group and Space expands/collapses it without starting playback. This required applying the existing control-focus scope to Data Privacy after the initial check exposed a playback shortcut conflict.

The final isolated production build, packaging, and signature checks passed through `make build-macos-preview` (63.99 seconds). The underlying build script is the same release build used by `make build-macos`. Existing Command Line Tools linker search-path warnings remain; no API deprecation warnings were introduced. The validated Data Privacy sources match the working tree. The user's active recording and installed app were not changed.

The complete Swift suite passed serially: 510 tests in 95 suites (64.13 seconds). The initial parallel run exposed folder-path regressions in the concurrent folder task and several five-second asynchronous test deadlines; path fixes and 13 focused asynchronous tests passed before the full serial run. Formatting, lint, and whitespace checks passed. Small-window, explicit Light selection, inactive-window rendering, and a real hour-long recording remain untested. No model inference or dependency was added by this change.
