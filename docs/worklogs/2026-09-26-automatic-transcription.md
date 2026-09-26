---
title: Automatic transcription with live text
date: 2026-09-26
status: implemented
scope: swift-app-settings
---

# Automatic transcription with live text

## Problem

Automatic transcription ran after every saved recording when enabled, including recordings with usable live text. Defaults offered no choice for retaining live text without submitting audio to a provider.

## Design before implementation

Captured and inspected the existing Defaults screen in isolated UI Preview before editing: a full-width **Automatically Transcribe Recordings** switch appeared below Default Language and above the upload disclosure. The [workflow design](../design/transcript-workflow.md) replaces it with **Automatically Transcribe**, using a native checkbox. An indented **Automatically Transcribe Even if a Live Transcript Exists** checkbox appears only while the first is enabled. The existing provider disclosure remains visible. The installed app's active recording was not touched.

## Implemented solution

`AppSettings` persists the override separately, defaulting missing keys to false. Disabling automatic transcription hides but retains the override choice. The pure policy requires automatic transcription and either the override or no usable finalized live text. The coordinated stop hook evaluates the policy after recognition finishes for the recording being saved; empty and provisional text do not suppress automatic transcription.

Data Privacy includes every configured provider available for manual transcription, retaining capability, credential, endpoint, upload-provider, and website sign-in checks. Only the default provider can have an automatic trigger. Shared upload destinations remain deduplicated. Automatic wording no longer claims audio is sent after every recording.

## Reasoning

These controls represent dependent Boolean choices, so native checkboxes allow both to be enabled. They use the supported [SwiftUI checkbox style](https://developer.apple.com/documentation/swiftui/togglestyle/checkbox). The new preference does not select a provider, trigger a request when settings change, or treat enabling live recognition as proof that text exists.

## Technical debt

None added. Provider eligibility and submission remain in the existing transcription flow.

## Validation

Formatting and lint passed. The integrated suite passed 261 tests in 54 suites, including all eight policy combinations, old-settings decoding, override persistence while automatic transcription is off, and alternate-provider privacy routes. An outdated privacy wording assertion found in the first run was corrected before the passing run. Existing Command Line Tools linker search-path warnings remain; no deprecated API was introduced.

Captured the changed Defaults screen in System appearance (dark on this Mac). Native checkbox layout matches the design, the override starts off, enabling the master reveals it, and disabling the master removes it. Automatic approval review rejected the override-on interaction without giving a reason; that interaction and light-appearance/keyboard checks remain unverified in UI. Persistence and policy combinations passed unit tests. No hardware capture or provider requests were made; Preview was quit for final packaging.
