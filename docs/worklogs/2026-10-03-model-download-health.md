---
title: Stable readiness during model downloads
date: 2026-10-03
status: complete
scope: swift-provider-health
---

## Problem

Local speaker provider settings forced capability checks on every model-state publication, including each downloaded byte update. Each check published Checking… before returning its result, causing repeated flashing. Both model cards also checked their files on every update from any model.

## Design

Inspected the supplied screenshot and captured the running Service Providers screen before editing. Preserve its Readiness rows, model cards, progress indicators, and installation controls. Byte progress should update the download indicator; readiness should update when the relevant model changes phase or reports an error. An unrelated model download should not trigger checks for the displayed provider.

## Implemented solution

LocalModelState exposes an equatable health identity containing its phase and message, excluding byte counts and leases. LocalSpeakerProviderView uses a SwiftUI task keyed to the saved provider model and shared association model identities. Each LocalModelDownloadView keys its health task to its own identity and discards cancelled results. Initial model discovery remains a separate task.

## Reasoning

Observing readiness inputs removes redundant work at its source without delaying download progress or adding a debounce interval. SwiftUI starts the task after state updates and owns its lifetime; the previous publisher callbacks created an unstructured task for every progress event.

## Technical debt

None introduced. Existing readiness checks and installation verification remain authoritative.

## Validation

Regression coverage checks that 100 progress updates, total-byte changes, and lease changes retain the health identity, while installation phases and messages change it. Formatting, lint, and diff checks passed. The isolated release build passed, including packaging and signing.

The initial full run executed 724 tests in 128 suites and reported 10 issues in unrelated timing-sensitive recording, task, and file-monitor tests while release compilation ran concurrently. Both local-model and provider-health suites passed. A serial rerun of those suites and every failing suite passed all 87 tests in 8 suites.

In isolated UI Preview, a real Community-1 download advanced from zero through 13.5 MB and 15.5 MB with unchanged readiness text and stable model controls. Completion changed both capabilities and model cards to Ready, including the shared association model. Captured screenshots during download and after completion matched the intended layout. Refresh retained Ready, and keyboard navigation remained available. The running production app and its library were not modified. Dark appearance, older macOS versions, and frame-by-frame animation capture were not tested.

Build warnings were limited to relocated cache files and existing missing Command Line Tools linker search paths. The copied compiler cache initially failed because its absolute path changed; removing that disposable cache allowed the release build to complete. No deprecated API warnings appeared. The toolchain search-path warning remains an environment issue; repair the Command Line Tools installation separately if it persists after updating.
