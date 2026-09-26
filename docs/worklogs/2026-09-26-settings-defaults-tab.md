---
title: Merge Transcription and Summaries settings into Defaults
date: 2026-09-26
status: complete
scope: client-macos-swift
---

**Problem:** Settings had separate **Transcription** and **Summaries** tabs, each holding one provider picker and little else. More per-capability defaults, such as Live Transcription, would each add another sparse tab.

**Implemented solution:** Replaced both tabs with one **Defaults** tab (`slider.horizontal.3`), placed after **Service Providers** because its pickers list providers configured there. The order is Recording, Service Providers, Defaults, Data Privacy. `UI/DefaultsSettingsView.swift` holds a grouped form with one `CapabilityDefaultSection` per capability: Transcription (provider and its caption) and Summaries (provider, **Summary Instructions**, and its caption). A section takes the capability, its `AppSettings` key path, a caption, and optional extra controls, so adding Live Transcription is one more section. When no provider qualifies, a section shows “Add a provider and turn on <capability> to choose it here.” with **Open Service Providers**; the picker stays while a saved choice exists so it can be cleared. Setting keys are unchanged.

Error messages now point to **Settings → Defaults**. **Set Up Transcription…** opens Defaults when a qualifying provider exists but none is chosen, and Service Providers otherwise. A saved `settingsTab` value of `transcription` or `summaries` opens Defaults. Updated the Swift README and the meeting-experience design. Added a test for the summary-provider error and tightened the transcription-provider error test.

**Reasoning:** **Automatically Transcribe Recordings** and **Default Language** stay under Recording → Transcription, because they were never in the Transcription tab and describe new recordings rather than a provider choice. A generic section view was chosen over a data table of capabilities because Summaries needs an extra control; a `@ViewBuilder` slot handles that without special cases.

**Technical debt:** The mapping of the legacy `transcription` and `summaries` tab values is a compatibility bridge for a saved UI selection. Without it, people whose last tab was one of those would open Settings with no tab shown. Remove it after a release in which those values can no longer be stored. Tab tags remain string literals shared by three views, as before.

**Notes:** `make format-macos`, `make lint-macos`, `make test-macos` (187 tests in 37 suites), and `make build-macos-preview` passed. The build kept the existing Command Line Tools linker search-path warnings. The Defaults form was checked with offscreen `NSHostingView` renders in Light and Dark appearance, with and without qualifying providers, using a temporary test that was then deleted. Offscreen rendering does not draw the Settings toolbar tabs, so the tab label, symbol, and keyboard navigation were not checked on screen. `DataPrivacy.swift` and `ServiceProvidersView.swift` contained no references to the old tabs and were not changed.

## Fold Recording into Defaults

**Problem:** Two tabs set defaults for new work. Recording chose sources, format, voice processing, **Default Language**, and **Automatically Transcribe Recordings**. Defaults chose providers. Both had a **Transcription** section.

**Implemented solution:** Removed the Recording tab. Settings now has **Defaults** (first, and the default selection), **Service Providers**, and **Data Privacy**. `UI/DefaultsSettingsView.swift` has three sections:

- **Recording:** Microphone, System Audio, a caption about New Recording and macOS permission, **Audio Format** and its caption, and **Turn On Voice Processing Automatically** and its caption. These controls are still disabled while a recording starts, runs, or saves.
- **Transcription:** Provider, **Default Language**, **Automatically Transcribe Recordings**, and the caption.
- **Summaries:** Unchanged.

The Recording tab's intro sentence became the sources caption, so "you can change them in New Recording" is kept. The tab had no library location or other setting. Setting keys are unchanged. `CapabilityDefaultSection` needed no API change, because its `@ViewBuilder` slot already accepts several controls. `SettingsView.currentTab(for:)` maps a saved `recording`, `transcription`, or `summaries` tab to `defaults`, and `SettingsTabTests` covers it. Every `settingsTab` default is now `defaults`. Every **Settings → Recording** reference now points to **Settings → Defaults**, in the Swift README, `AUDIO_DESIGN.md`, `UI_PREVIEW.md`, `docs/protocols/transcription.md`, `docs/design/live-transcription-research.md`, and `docs/design/meeting-experience.md`. The last one also lists the new tab groups.

**Reasoning:** **Default Language** comes after Provider because its choices come from the selected transcription provider. One Recording section with a caption under each control avoids three one-control sections. Deep links needed no change: none opened the Recording tab, and the links that open Defaults and Service Providers still work.

**Technical debt:** The legacy tab mapping now also covers `recording`. Its reason and removal plan are the same as above.

**Notes:** `make format-macos`, `make lint-macos`, `make test-macos` (189 tests in 38 suites), and `make build-macos-preview` passed. The existing Command Line Tools linker search-path warnings remain. Defaults was rendered offscreen with `NSHostingView` at 748 pt width, in Light and Dark appearance, with and without synthetic providers. The temporary test that made these renders was deleted. Switches look inactive because the offscreen window never becomes key. The toolbar tabs and their order were not checked on screen.
