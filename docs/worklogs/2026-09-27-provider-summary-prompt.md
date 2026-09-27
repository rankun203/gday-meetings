---
title: Provider summary prompt
date: 2026-09-27
status: implemented
scope: swift-summary-provider
---

## Problem

Summary instructions were a global Defaults field and differed from the Rust client's structured summary prompt. Generated citation instructions also need timestamps in the supplied transcript.

## Implemented solution

- Each OpenAI-compatible provider owns Summary Prompt, with a scrollable editor and Restore Default in Service Providers. Defaults retains the summary provider picker.
- Summary requests use the selected provider's prompt, followed by language and current local time. The default instructions match Rust's `chat/summarize.rs` task, output format, and rules.
- Summary input supplies meeting metadata, notes, participant names and notes, and timestamped transcript, excluding the previous generated summary. Chat behavior is unchanged. Data Privacy reflects participant notes and the renamed prompt.
- Decoding migrates customized global instructions to the selected provider without replacing an existing provider prompt. Without a selection, the first LLM provider without a custom prompt receives them. If no suitable provider exists, a pending migration field preserves instructions across saves and retries when providers or selections change. Existing stock Swift instructions become the Rust default.

## Reasoning

The provider panel groups the prompt with the endpoint and model used for the request. The parent agent captured and inspected the existing Defaults and provider panels before UI edits: the old global field occupied Defaults, and the provider panel had connection, model, capabilities, and save controls. The new bounded editor follows Connection and precedes Capabilities. Save preserves the existing draft workflow.

## Technical debt

The legacy global decoding key remains as a compatibility bridge so existing customized instructions survive upgrade. The legacy key is decode-only. A pending migration field retains dormant custom instructions until a provider can receive them, then clears; it is never used directly for summary requests. Remove these fields only when older settings migration is no longer supported and pending values have been handled. The prompt text is duplicated across the Rust and Swift clients because they ship independently; validation compares their static instruction text. Keep both defaults synchronized when intentionally changing the common instructions.

## Notes

Focused migration and request-context tests added. The full suite passed 320 tests in 66 suites. A source comparison verified exact equality of the 1,159-character Rust and Swift default instructions. Preview screenshots confirm the bounded provider prompt editor and Restore Default control; typing updates the draft, Restore Default restores the full instructions, and Defaults no longer exposes the global field. The keyboard can focus and edit the native text area. Provider persistence and migration are covered by tests; no live completion was sent. Final migration changes were rebuilt after these visual checks; they do not change the layout. Swift has no tag notes or per-word ASR confidence in the summary input, unlike Rust. No live model request was sent for validation.

Formatting, lint, and Preview build checks completed. Known Command Line Tools linker search-path warnings remain, tracked in [the toolchain worklog](2026-09-25-swift-keychain-deprecations.md); no new deprecation warning was observed. Provider-specific dark appearance and full keyboard traversal were not separately exercised.
