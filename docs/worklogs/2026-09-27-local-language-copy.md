---
title: Remove repeated language guidance
date: 2026-09-27
status: implemented
scope: swift-app-provider-settings
---

## Problem and design

The user's before screenshot shows two explanatory rows above the local language list. They repeat information already conveyed by language names, model labels, installation status, and download controls. Remove both rows so the Live Transcription section starts with the language list, or its existing loading and availability message.

## Implemented solution

Removed the two static guidance rows from `ThisMacProviderView`. Language mapping, ordering, model status, and download actions are unchanged. The surrounding copy follows `docs/writing.md`; the remaining header explains the separate on-device audio and model-download behavior.

## Validation

Shared formatting, lint, the 308-test suite, and production build passed. The supplied before screenshot was inspected and matched against the source. The after-change Settings screenshot was not completed because computer-use reported user activity; no settings or model downloads were changed. The source change removes only the two text rows, retaining the language list and its controls. Existing Command Line Tools linker search-path warnings remain.

## Technical debt

None.
