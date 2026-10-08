---
title: Honor General search provider selection
date: 2026-10-08
status: complete
scope: swift-app-search
---

# Honor General search provider selection

## Problem

The results page exposed a Text/Semantic switch that persisted a separate mode setting. A saved Text choice could override the Local Search provider selected in General and disable model preparation. Fresh synthetic Preview folders also lacked the installed model, so they were unsuitable for validating configured Local Search.

## Implemented solution

Remove the results-page mode picker and obsolete saved mode property. Use a shared selected-provider lookup for submission and model preparation. Ignore old mode keys when decoding settings and omit them when saving. Keep the internal text-index implementation for indexing and backend tests.

Use the full isolated app with a temporary copy of the configured library, models, and settings. Clone files independently, snapshot the open SQLite database through its backup API, and disable the copied pending-task journal for search-only validation. Keep real-content captures outside the repository and delete the validation copy after quitting the app.

## Reasoning

General is the single source of truth for provider selection. A missing or disabled selected provider must produce an actionable error rather than silently use Text search. A copied library exercises the actual installed model and index without changing the original data folder.

## Technical debt

None.

## Validation

Captured the old search-page mode override before validation. Added tests for obsolete Text, Fusion, and Semantic settings, selected-provider preservation, removed-provider migration, and unavailable-provider handling.

Formatting, lint, and diff checks passed. The isolated release build passed with deployment-target, packaging, and signature checks (`tmp/search-open-validation/general-search-release.log`). Existing Command Line Tools linker search-directory warnings remain; no source deprecation warnings appeared.

Launched a separately identified full-app bundle with `GDAY_SWIFT_DATA_DIR` pointing to the temporary copy. Focusing search showed no model download prompt. A generic query completed through Local Search and returned 100 matches grouped into 60 meeting rows. The results page had no Search Mode or match dropdown. Inspected the rendered page and kept its real-content capture only in the temporary validation folder.

Quit the validation app, confirmed it had exited, and deleted the temporary library, copied app, and capture. Confirmed the temporary folder was gone and the original library remained present. No real meeting content was added to repository files. All 18 focused tests passed in `LocalSearchConfigurationTests` and `TaskAttentionTimingTests` (`general-search-tests.log`).
