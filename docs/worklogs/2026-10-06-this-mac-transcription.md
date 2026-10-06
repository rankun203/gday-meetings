---
title: This Mac recorded transcription
date: 2026-10-06
status: complete
scope: swift-app
---

# This Mac recorded transcription

## Problem

The Transcribe and Re-transcribe menus listed configured remote providers only. This Mac supported live recognition but could not transcribe saved audio.

## Implemented solution

- Add This Mac first in the existing native provider menu, using the same managed task queue, saved results, edit-conflict protection, and transcript history as remote transcription.
- Process saved audio with SpeechAnalyzer. Decode Opus to a temporary CAF using the current streaming Opus decoder, remove temporary audio after processing, and retain per-track timestamps and source placeholders. Speaker labeling remains a separate capability.
- Add recorded transcription enablement and readiness to This Mac settings and make it available as the default transcription provider. Migrate existing settings once without changing their live transcription choice or default provider.
- Retain local attempts across retries and record local data processing in Data Privacy.

## Reasoning

The supplied screenshot shows a compact native menu with only a remote provider. Keep its layout and add This Mac as the first row; preserve disabled, pending, and saved-result states. Settings uses its existing capability switches and readiness rows. A file-input analyzer avoids feeding saved recordings into the live queue, which can drop audio when recognition falls behind capture.

Apple's [SpeechAnalyzer file input](https://developer.apple.com/documentation/speech/speechanalyzer/analyzesequence(from:)) returns after reading; explicitly finalize analysis and collect final timed results before saving. Cancel the analyzer and drain its results task on failure or cancellation. The APIs support the macOS 26 minimum; validation uses the installed macOS 27 SDK.

## Technical debt

The existing `ViewState` compatibility alias remains necessary with the installed Command Line Tools SDK, which lacks the SwiftUI State macro plugin. One pre-existing `@State` declaration blocked validation; align it with the surrounding `@ViewState` declarations. Remove this alias once the supported toolchain resolves the macro issue, as already tracked in the native-client worklog. No new compatibility mechanism is introduced. The capability version is a persisted settings migration that preserves explicit disablement on subsequent launches.

The older Core Audio Opus preparation helper remains in unrelated service paths. It failed the generated app-encoded Opus fixture during investigation. This path uses the existing libopusfile decoder instead. Follow up by migrating the remaining preparation callers to libopusfile and retaining their corrupt-input regression coverage; the older helper may still reject valid recordings in those paths.

## Validation

- Passed 39 focused tests covering provider routing and readiness, settings migration, transcript history, and generated English speech on both AIFF and app-encoded Opus tracks. Passed the five local tests again after correcting CAF output settings. Verified per-source text, timestamps, source placeholders, and saved-result edit protection.
- Formatting, strict lint, and whitespace checks passed.
- Release build, signing, and final Preview packaging passed in an isolated source copy. The final release build completed in 105 seconds.
- The toolchain reports existing missing linker search paths under `CommandLineTools/Developer/usr/lib` and `CommandLineTools/Developer/Library/Frameworks`. These are not deprecation warnings. They match the previously documented CLT installation issue; validate the selected CLT installation when updating the toolchain. No deprecated API warning was emitted.
- The first Opus smoke test exposed a failure in the older Core Audio conversion helper. This implementation uses the current libopusfile decoder already used by playback. The final synthetic Opus test passed; the older helper is unchanged.
- Captured the final Preview menu and This Mac settings through computer-use screenshots. This Mac appears first beside RunPod in the existing native menu, with descriptive accessibility labels. Settings shows separate capability switches and readiness rows without clipping. Light appearance, 2218 × 1324 meeting screenshot; settings screenshot 1920 × 1616. Source snapshot: `tmp/this-mac-transcription/working-tree.diff` plus the two new Swift files beside it. Exact bundle: `tmp/this-mac-transcription/apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`, revision label `this-mac-transcription-final`, built October 6 at 16:19 local time, with `GdaySyntheticProviders=true`.
- Runtime: macOS 26.6.2, Swift 6.4, SDK 27.0, deployment minimum macOS 26.0. The normal app remains running. Build and UI artifacts use ignored `tmp/this-mac-transcription`; no private meeting content is copied into fixtures or documentation.
- Validation limits: keyboard activation was not established (the automation dismissed the menu and returned focus to the transcript); dark appearance and narrow-window layout were not checked. Transcription accuracy across languages, long-recording throughput, and cancellation during an Apple model download were not measured.
