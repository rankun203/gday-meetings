---
title: Normalize provider transcript whitespace
date: 2026-09-28
status: complete
scope: swift-transcription
---

# Problem

Provider text could retain leading and trailing whitespace in saved segments and live phrases, producing inconsistent sentence indentation.

# Implemented solution

Trim surrounding whitespace and newlines at the shared batch-provider result conversion and live-provider receive boundary, before display or persistence. Preserve internal whitespace, segment identity, speaker assignment, timestamps, and timed word records. Live highlights derive their ranges from the normalized phrase. This is an ingestion change; no UI layout changes or existing-library rewrite is included.

# Reasoning

Both batch transports share one conversion path. Live partial and final results share one receive path. Normalizing these boundaries prevents provider whitespace from entering new transcript content without modifying user edits or historical versions.

# Validation

Formatting, lint, and all 427 tests in 85 suites passed. Regressions exercise padded batch results and saved live phrases, internal spacing, timestamps, word records, and highlight ranges. No live recording or personal library was touched. No UI layout changed, so validation used ingestion and persistence tests rather than a new screen comparison. The existing Command Line Tools missing library/framework search-path warnings remain; no deprecation warnings were introduced.

# Technical debt

None. Existing stored transcripts remain unchanged; the saved-transcript view retains its existing display guard for older leading whitespace.
