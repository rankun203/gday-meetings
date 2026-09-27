---
title: Automatic summaries after transcription
date: 2026-09-27
status: implemented
scope: swift-summary-automation
---

## Problem

Generating a summary required a separate action after a live or provider transcript became available.

## Design before implementation

Inspected the supplied Defaults screenshot: Summaries contains the provider picker and a transfer caption. Add an Automatically Summarize checkbox directly below the provider picker, matching Automatically Transcribe, followed by a short explanation of live and provider completion behavior. The setting starts off and persists. Existing meetings are not processed merely by enabling it.

## Implemented solution

The Defaults checkbox controls automatic summaries after a saved live transcript at recording stop or a successfully applied provider result. Data Privacy includes automatic transcript-triggered text transfer to the summary provider. Requests use that provider's Summary Prompt.

## Reasoning

Live and provider transcription are separate completion events. The later result must not be dropped merely because the earlier summary is running. Pending work uses the newest saved transcript after the current summary finishes. Only successful transcript saves trigger work.

## Technical debt

Pending summary work is in memory. Quitting does not resume or retry these LLM requests, avoiding accidental resubmission after an ambiguous remote response. A future durable job design would need request identity and explicit retry semantics.

## Validation

Passed `make format-macos`, `make test-macos` (326 tests in 67 suites), `make build-macos-preview`, `make lint-macos`, and `git diff --check`. Loopback HTTP tests verify two summary requests with distinct live and provider transcript bodies, including when the first request was manual. Tests also cover persistence, disabled automation, queued work disabled before launch, empty transcripts, discarded attempts, failed saves, and automatic Data Privacy routes.

Captured the changed Defaults panel in isolated Preview, in System (dark) appearance. The checkbox sits below provider selection/setup and above the transfer caption, with explanatory text fully visible. Clicking it changed its accessible state on and off; it was left off. Light appearance, complete keyboard traversal, and minimum-OS rendering were not separately checked for this native checkbox. No production provider request or hardware recording was used.

Known Command Line Tools linker warnings for missing Developer library/framework search paths remain; no new deprecation warning was observed. Remediation remains tracked in [the toolchain worklog](2026-09-25-swift-keychain-deprecations.md).
