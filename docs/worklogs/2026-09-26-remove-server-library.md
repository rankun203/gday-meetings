---
title: Remove remote library navigation
date: 2026-09-26
status: complete
scope: client-macos-swift-and-active-designs
---

## Problem

Server Library remained a separate sidebar destination and transcript search/import flow after connections moved into Settings → Service Providers. It duplicated the app's library concept and advertised a remote search operation that is no longer part of the native workflow.

## Implemented solution

- Removed the destination, its intermediate column, and `ServerLibraryView`. The sidebar now contains Meetings, People, and Tags. Local meeting search and the list's insertion-scroll behavior remain.
- Removed the exclusive website search adapter, request method, and search-result model. Website sign-in, transcription, and Archive to Server remain provider operations.
- Stopped advertising Search for website providers and removed its Data Privacy data type, trigger, and routes. Updated the tests and provider help text.
- Updated the active navigation design, recording brief, and search protocol implementation status. The old generated concept remains historical evidence linked from its original worklog, but no longer appears as an active navigation reference.

## Reasoning

Remove the unused request path as well as its view so a hidden, unsupported workflow cannot remain callable from the app. Keep the generic Search provider contracts as proposed extension points; they do not submit requests or appear as an available provider capability.

The scope is the current native Swift app and its active designs. The Rust reference client and website's own search API are separate implementations and remain unchanged. No service request or content submission was made.

## Validation

Formatting, lint, diff checks, and Preview packaging passed. A compatibility regression verifies that a saved website Search setting still decodes, cannot enable Search, and does not disable transcription. Privacy tests now expect only available website actions. All 217 tests in 43 suites passed. Known Command Line Tools linker search-path warnings remain; no deprecation warnings were reported.

Preview navigation showed only Meetings, People, and Tags. Local search remains available. Repository search found no Server Library references in the Swift app or active design text.

## Technical debt

The Codable `search` capability case remains so existing settings can open without a schema migration. No provider advertises or supports it. The generic `SearchProvider` and `SearchIndexProvider` contracts remain future extension points; implement an explicit provider workflow and update its privacy disclosure before enabling them, or remove them with a settings migration if remote search is abandoned entirely.
