---
title: Shorter automatic people association label
date: 2026-10-03
status: active
scope: swift-app-ui
---

## Problem

The automatic speaker association label was longer than neighboring switches in General settings.

## Implemented solution

Use **Automatically Associate People** in Recording and After Recording. Update the writing guide to use the same wording.

## Reasoning

The supplied image and a fresh General screenshot showed the existing rows. Shorten both labels while retaining their positions, independent bindings, readiness indicators, and the explanation linking speaker association to the People Library. The shared label also supplies the accessible control name.

## Technical debt

None.

## Notes

Formatting, lint, and diff whitespace checks passed. The isolated `make build-macos` release build passed in 197.84 seconds with plist and signature validation. The initial sandboxed attempt could not run the SwiftPM manifest; the authorized retry completed outside that sandbox. Existing Command Line Tools linker warnings report missing library and framework search paths; no deprecated API warnings were emitted.

A final synthetic Preview screenshot in System/light appearance shows both complete labels with stable row alignment and independent Ready/Off states. Accessibility exposes the new names. The concurrent-input guard interrupted the toggle interaction check; keyboard activation, dark appearance, other window sizes, and older macOS versions remain untested. No automated tests were added for this wording-only change.
