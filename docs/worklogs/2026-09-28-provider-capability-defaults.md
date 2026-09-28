---
title: Provider capability defaults
date: 2026-09-28
status: validating
scope: swift-provider-settings
---

# Problem

New providers required capabilities to be enabled separately. This Mac had a fixed label in Defaults and no capability control in Service Providers.

# Design and implementation

The user’s Settings screenshot is the baseline. Keep the grouped forms, add a Capabilities section with Live Transcription to This Mac, and keep downloads in a separate Speech Models section. Defaults uses a Provider picker with None and eligible This Mac. Turning off its capability keeps the saved choice visible as Provider Unavailable. Recording starts live transcription only when This Mac is selected, its capability is enabled, and Show Live Transcript is on.

New provider instances enable their complete supported capability set. Editing or decoding an existing provider retains its explicit choices. No remote live-transcription implementation is advertised. Built-in provider identity and supported capabilities now live in the service model, not a view.

# Validation

Added tests for every new provider kind, disabled choices across edits and serialization, and live-transcription routing and disabled selection persistence. All ten focused ServiceProviderTests passed (/tmp/gday-capability-tests.log). Existing disabled-provider submission coverage now explicitly turns capabilities off. Visual verification is pending coordination with the parent agent.

Preview verification passed: This Mac shows Live Transcription enabled in its Capabilities section. Adding a RunPod provider shows both Transcription and Speaker Labels enabled before saving; no remote request was made.

# Technical debt

None. This change adds no data migration or compatibility bridge. Existing development settings without the new live provider selection need This Mac selected once in Defaults.
