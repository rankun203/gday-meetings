---
title: Live and saved transcript workflow
date: 2026-09-26
status: in-progress
scope: swift-app-transcription
---

# Live and saved transcript workflow

## Existing screen

Before implementation, the current Preview Transcript and Defaults screens were captured and inspected. The user's recording screenshot shows live text in a nested scroll area inside the recording card: scrolling moves settings underneath the fixed meters and clips the Live Transcript control. The saved Transcript tab already uses timed text rows, but live text is separately presented as a draft that requires manual adoption.

## Intended layout

The recording card contains the timer, date, stop action, meters, and recording settings. Live text belongs to the Transcript tab. Its status and controls stay outside the text's scrolling viewport. Live text uses timed rows without speaker attribution; input tracks are not people. Following new text must not scroll the recording settings or prevent reading earlier text.

After recording, finalized live text becomes the meeting transcript when doing so will not overwrite existing edits. The independent live checkpoint remains recoverable. Transcription failure, unavailable live recognition, or a disabled live setting must not prevent audio recording or saving.

## Saved recording actions

- Without text, offer **Transcribe with [Provider]** for one eligible provider.
- With text, offer **Re-transcribe with [Provider]** for one eligible provider.
- With multiple eligible providers, offer a menu to choose the provider for this operation. The choice does not change the default provider.
- With no eligible provider, offer an action to configure one.
- Keep existing text while a request runs. Preserve its revision before applying a replacement, and protect edits made while a request is running. Existing pending requests retain their provider and can be resumed.

Keeping the built-in live transcript requires no cloud request. This Mac's live capability does not imply an implemented saved-audio transcription capability.

## Automatic transcription

Defaults → Transcription contains two checkbox controls: **Automatically Transcribe** and **Automatically Transcribe Even if a Live Transcript Exists**. The second appears only when the first is enabled and defaults to off. These are dependent Boolean settings, not mutually exclusive radio choices.

Evaluate the policy after live recognition finishes. With automatic transcription enabled, recordings without usable finalized live text use the selected transcription provider. Recordings with finalized live text use that provider only when the second option is enabled. Empty live sessions do not suppress transcription. Existing provider eligibility and upload rules remain in force.

## Validation

Check live, disabled, unavailable, stopped, and empty transcript states; zero, one, and multiple transcription providers; pending requests and replacement conflicts; short-window scrolling; light and dark appearances; and the dependent Defaults controls. Use synthetic Preview data and isolated tests without hardware capture or provider uploads.
