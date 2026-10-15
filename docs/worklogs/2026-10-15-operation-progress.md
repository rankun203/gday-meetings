---
title: Progress for indexing and other operations
date: 2026-10-15
status: complete
updated: 2026-10-16
scope: macos-task-progress
---

## Problem

Indexing and voice preparation had numerical counts but no structured progress. Import, archive, chat, and recording pipeline stages lacked consistent phases.

## Implemented solution

- Search indexing reports completed passages and estimates remaining embedding time from the character count of passages that need new vectors. Core ML measures inference inside its permit; model preparation, queue waits, cached vectors, and persistence do not train the speed cache. Successful persistence returns a measurement receipt to the awaited caller, independent of asynchronous UI updates.
- Search rebuilds expose completed meeting counts. Different meeting lengths make count-based time estimates unsuitable.
- Voice preparation keeps time estimates in a transient presentation overlay, without writing recovery checkpoints. Each run inventories pending speech duration once and decrements it as examples settle. It separates recording discovery, example preparation, and comparison. Example estimates use speech duration and successful inference time measured inside both processing permits. Paused jobs hide estimates, and resumed phases restart their elapsed-time origin.
- Archive preparation counts files; uploads count bytes in fully uploaded files. Audio import counts processed files. These APIs do not expose within-file transfer progress.
- Summary generation, chat, speaker association, to-do extraction, and recording finalization report their preparation, processing, and saving phases. Context chat counts loaded meetings.

## Reasoning

A phase can report a percentage only when its total is known. Inference speed estimates describe the current phase. Recording discovery retains counts without an estimate because its complete audio workload is not available without opening the full inventory. Comparison and language-model output remain indeterminate.

## Technical debt

None. Optional progress metadata preserves existing saved jobs. Unmeasured embedding implementations retain their existing behavior and provide no timing sample.

## Validation

Added synthetic tests covering fresh versus reused embedding measurements, persisted receipts, voice phase changes after discovery failures, paused estimates, rebuild counts, and verification that repeated voice time estimates leave checkpoint bytes and revisions unchanged. Parent task coordinates test runs, code review, and the release build. UI validation is recorded in the parent task worklog.

Final release, test, review, and UI results are recorded in the [parent worklog](2026-10-15-task-progress.md).
