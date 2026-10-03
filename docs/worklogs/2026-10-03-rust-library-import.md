---
title: Rust library import
date: 2026-10-03
status: implemented
scope: manual-library-migration
---

## Problem

The user requested a complete import from the Rust client library into the current Swift library, including RunPod voice samples. The older importer used random identities, omitted some supporting files, and could not safely establish embedding-model compatibility.

## Implemented solution

Added `rust_library.py` and synthetic tests under the Swift migration scripts. Dry run is the default. Apply requires both apps to be stopped and a new, hash-verified full destination backup. Imported files are staged, then published without overwriting existing files; source and destination inventories are checked before and after publication. Exceptions remove files published by that attempt. Stable identities and a private manifest support reruns and preserve later destination edits.

The importer converts canonical transcript rows, notes, summaries, to-dos, tags, speakers, people, audio, and attachments. Exact complete audio-set hashes identify an existing destination meeting without title matching. Its current content remains unchanged. Source JSON, word-level transcript details, unsupported profile fields, tag notes, and conversations are archived. Settings and credentials are excluded.

## Reasoning

Voice samples preserve exact numerical values, confirmation multiplicity, session provenance, and explicit RunPod origin. A provider name or vector dimension does not establish a model revision. Samples retain unknown legacy compatibility, so the importer cannot silently enable comparisons against a different current model. Exact vector and person evidence are required to link a sample to a speaker. Person names alone do not authorize identity merging.

The importer preserves destination tag visibility when a matching tag name already exists and reports that choice. Deleted source profiles remain unresolved; their original assignments remain archived. Invalid optional speaker vectors are archived and omitted from current speaker records. Invalid confirmed person samples stop migration for review.

## Technical debt

The Swift schema cannot represent Rust confirmation dates, sample durations, profile history, tag notes, or standalone conversation state. These fields remain in source archives with stable mappings, but are not exposed by current app features. A future explicit schema conversion can expose them without losing provenance. Historical RunPod embeddings lack verifiable model and revision metadata; enabling automatic matching requires establishing that metadata or re-extracting samples with a current typed provider. No application startup compatibility bridge was added.

## Validation

Sixteen new synthetic tests pass, alongside thirteen existing transcript migration tests. They cover preservation, exact voice values and duplicate samples, canonical rows, assets, existing-meeting reuse, reruns after user edits, destination conflicts, source and destination changes, symlinks, invalid data, missing metadata, ambiguous audio matches, rollback, running applications, and backup conflicts. An independent reviewer validated generated records with the actual Swift Codable models and verified exact transcript text/times and all confirmed sample vectors. The command preserves the disposable index; the maintenance operator must rebuild it after importing.

## Import result

The authorized import completed with a full hash-verified destination backup. All source files and preexisting destination files remained unchanged during import. Independent post-import checks decoded the resulting library with the current Swift models and verified exact imported transcript text/times and voice vectors against source records. The old disposable index and event cursor were moved to a separate recovery folder. The validated release reopened the library and rebuilt the index; meeting and search counts matched the authoritative folders, and SQLite integrity validation passed. Private mappings and source-specific review details remain in the library manifest, outside the repository.
