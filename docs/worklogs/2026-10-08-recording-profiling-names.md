---
title: Identify recording work in Instruments
date: 2026-10-08
status: complete
scope: macos-recording-profiling
---

# Identify recording work in Instruments

## Problem

Time Profiler shows runtime worker threads under the process name, making recording work difficult to distinguish. The app creates no dedicated `Thread` or pthread workers. Its explicit dispatch queues already have descriptive labels. Swift concurrency and framework workers can execute different operations on the same thread.

## Implemented solution

Added Swift 6.2 task names at recording, speaker labeling, voice embedding, identity review, transcript delivery, storage, and model preparation entry points. Names identify the operation; source-specific tasks include only the fixed audio source name. Added `OSSignposter` intervals for live transcript refresh, live speaker audio processing, and voice embedding extraction. Each invocation has a separate signpost ID and ends through `defer`, including error exits. No meeting content or identifiers enter profiling labels.

Use the Swift Tasks instrument (in the Swift Concurrency template) to see task names and Points of Interest to see the three operation intervals under `com.gdaymeetings.macos`. These labels require a new build and capture; they do not rename Time Profiler's shared thread rows or alter existing traces. App intervals do not replace Core ML's internal prediction or accelerator events.

## Reasoning

Task names follow asynchronous work across thread switches. Renaming a shared worker from inside a task would incorrectly label unrelated later work. Framework threads remain under framework control; introducing dedicated executors only to label them would change scheduling without addressing the performance problem. The signposts also expose selected CPU work independently of Core ML instrumentation.

Current references: [Swift task naming](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0469-task-names.md), [Apple: What's new in Swift](https://developer.apple.com/videos/play/wwdc2025/245/), and [OSSignposter](https://developer.apple.com/documentation/os/ossignposter). Swift 6.2 and macOS 26 are already the repository minimums.

## Technical debt

None. This change adds diagnostic metadata without changing executors, priorities, cancellation, model behavior, or UI.

## Notes

Validation passed: `make format-macos`, `make lint-macos`, `git diff --check`, and `make build-macos` in an isolated source copy. Release packaging verified macOS 26.0 minimum, SDK 27.0, the bundle property list, and signing. The existing `LiveTranscriptStreamTests`, `LiveTranscriptDeliveryTests`, and `LiveObservationReviewMailboxTests` passed: 27 tests in three suites using the release configuration. No additional tests were added for task metadata.

The release and test builds emitted linker warnings about absent Command Line Tools search paths: `/Library/Developer/CommandLineTools/Developer/Library/Frameworks` and `/Library/Developer/CommandLineTools/Developer/usr/lib`. Both paths are absent from the installed toolchain; these are build-environment warnings, not deprecated APIs. They were not suppressed. No deprecation warnings were emitted.

The isolated build is `/private/tmp/gday-profiling-names.HH3Jtu`; logs are `/private/tmp/gday-profiling-names-release.log` and `/private/tmp/gday-profiling-names-tests.log`. The active recording and installed app bundle were untouched. Installed Xcode lists both `Swift Tasks` and `Points of Interest`. Their display of the new labels still needs a fresh capture using the new build. No UI, model output, or accelerator behavior changed. No push or CI run was requested.
