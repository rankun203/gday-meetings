---
title: This Mac speech model languages
date: 2026-09-26
status: complete
scope: swift-app-provider-settings
---

## Problem

The model list did not explain which English region the app uses. Installed models were mixed with models that require downloads, and a completed download refreshed only its own row.

## Implemented solution

This Mac settings use the shared app language catalog, matching New Recording. Each row shows the standard choice and the exact supported Apple locale used for recognition. English maps to English (United States); other English regions are omitted. Chinese script choices remain separate. Italian and Cantonese preserve language families from Apple’s current supported inventory. Unsupported choices, including Arabic and Russian on this Mac, remain visible as unavailable.

The adapter uses the same mapping as model settings and accepts only an exact supported locale after normalizing identifier separators. It does not silently substitute another English region or Chinese script. The list refreshes all model statuses after a download, then puts installed models first and sorts displayed names alphabetically within each group. Existing assets are preserved.

## Reasoning

Language choice belongs to the app, while provider-specific language identifiers belong at each adapter boundary. Keep Settings and recognition on one mapping so downloading a model cannot imply a different recognition language. A supported locale is not proof of a separate download; Apple manages shared model assets.

## Validation

Formatting and lint passed. All 250 tests in 52 suites passed, including exact English/Chinese locale mapping, unsupported locale rejection, installed-first ordering, refreshed ordering, and provider-boundary regressions. Preview packaged successfully. Known Command Line Tools missing linker search-path warnings remain; no new deprecation warning appeared.

Preview UI checks passed in Light and System dark appearance: standard language names and regional model subtitles remain readable, extra English regions are absent, Chinese choices remain separate, and Arabic/Russian show unavailable. New Recording offers all 13 standard choices without a provider; selecting Chinese (Traditional) works. Installed-first ordering is covered by a synthetic status regression because this fresh Preview session reported downloadable models. Download completion was not exercised; the completion path refreshes the entire inventory. Full keyboard navigation and older macOS appearance were not rechecked.

Read-only Apple inventory listed 29 regional locales across German, English, Spanish, French, Italian, Japanese, Korean, Portuguese, Cantonese, and Chinese. A standalone helper reported supported status for English (US) and both Chinese regions; that process does not establish an earlier app session’s installation or download history. No audio capture, model download, asset removal, or installed-app replacement occurred. The updated build is packaged in isolated Preview; the running installed app was not replaced.

## Technical debt

None. Apple manages model storage; this screen reports current availability and does not reconstruct download history.
