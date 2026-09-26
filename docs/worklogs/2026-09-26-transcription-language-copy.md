---
title: Clarify transcription language help
date: 2026-09-26
status: complete
scope: client-macos-swift
---

## Problem

The language help popover described where the language list came from and when it was fetched. That detail did not help someone choose the language spoken in a recording.

## Implemented solution

- Kept the heading “Transcription Language” and changed its explanation to “Choose the language spoken in the recording.”
- Removed built-in list provenance and cached-list timestamps from the popover.
- Reviewed unavailable, loading, failed, disabled-provider, and unsupported-language states. Kept provider names where they identify a setting to change or explain an unsupported selection.
- Used “Load languages to choose one for this recording.” for an unloaded list, “Loading languages…” during loading, and “Couldn’t load languages.” before the existing error detail and retry action.
- Pointed the missing-provider message to Settings → Defaults. Kept the existing “Load Languages” action for explicit loading and refresh.

## Reasoning

The help text now explains the choice and recovery actions. It follows `docs/writing.md`: sentence case for explanations, title case for controls, and concrete settings paths. The language list, supported languages, and request behavior are unchanged. RunPod still uses its built-in list without language-discovery requests.

## Technical debt

None.

## Validation

Reviewed all picker states and surrounding labels against the writing guide. This wording-only change does not add tests that duplicate interface strings. Formatting passed. The installed app’s language popover was checked through its accessibility tree and showed the revised heading and instruction without provenance text.
