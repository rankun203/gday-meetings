---
title: Consistent service provider icons
date: 2026-10-02
status: implemented
scope: swift-app-settings
---

# Problem

The local speaker provider header reserved space for an icon but displayed none. AppKit returned no image for `waveform.badge.person.crop`. After replacing it, the sidebar still showed a computer icon and the Add Provider menu had no icons.

# Implemented solution

Define `ServiceProviderKind.systemImage` and use it in sidebar rows, local and remote detail headers, and Add Provider menu labels. Nemotron and Community-1 use `person.wave.2`; the website uses `globe`; RunPod, OpenAI-compatible, and Filedrop use `server.rack`.

# Reasoning

The person and sound waves represent speaker processing. A shared mapping keeps provider identity consistent across selection and configuration. Keep native labels, fonts, placement, and controls. Captured and inspected the running settings before editing, including the mismatch and text-only Add menu. The intended design places each provider's symbol before its name in the sidebar, header, and menu.

# Technical debt

None.

# Validation

AppKit resolves the replacement symbol. Formatting, lint, and diff checks pass. `make build-macos` passed in an isolated checkout (206.72 seconds), including plist and signing validation. Inspected screenshots of both provider forms in isolated UI Preview: the symbol appears beside each title with native alignment. Adding and selecting the synthetic providers worked. Surrounding wording remains consistent with the writing guide.

The first sandboxed build failed because Swift could not launch its manifest sandbox; the permitted build outside that sandbox passed. The linker reported existing missing Command Line Tools Developer library and framework search paths. These toolchain warnings remain; use a complete Xcode installation to resolve the paths. No deprecated API warnings appeared.

Visual checks cover light appearance on this Mac. Dark appearance, older macOS versions, and VoiceOver were not exercised. No model downloads, inference, or recording controls were invoked. The installed app and active model use remain untouched. No commit or push was requested; remote CI was not run.

The follow-up shared mapping and menu labels pass formatting, lint, and diff checks. The isolated release rebuild passed in 69.50 seconds with the same two linker search-path warnings. Preview screenshots show all six Add menu options with their mapped icons, and matching sidebar/header symbols for Community-1 and RunPod. Selecting those menu options adds and selects the expected provider. No credentials or remote jobs were used. Validation isolates these provider changes from concurrent transcript work in the main checkout.

The user subsequently requested committing and pushing all remaining files. Reviewed the complete diff and confirmed all four changed Swift files match the later release-validated installed snapshot. Lint and diff checks passed again. The earlier statement about leaving the installed app untouched describes the isolated icon validation; the later transcript release installation included these same icon changes.
