---
title: Live and saved transcript workflow
date: 2026-09-26
status: implemented
scope: swift-app-transcription
---

# Live and saved transcript workflow

## Existing screen

Before implementation, the current Preview Transcript and Defaults screens were captured and inspected. The user's recording screenshot shows live text in a nested scroll area inside the recording card: scrolling moves settings underneath the fixed meters and clips the Live Transcript control. The saved Transcript tab already uses timed text rows, but live text is separately presented as a draft that requires manual adoption.

## Intended layout

The recording card contains the timer, date, stop action, meters, and recording settings. Live text belongs to the Transcript tab. Its Live Transcript switch, status, and Follow Live control stay outside the text's scrolling viewport. Live text uses timed rows without speaker attribution; input tracks are not people. Following new text must not scroll the recording settings or prevent reading earlier text.

After recording, finalized live text becomes the meeting transcript when doing so will not overwrite existing edits. The independent live checkpoint remains recoverable through Transcript History. Legacy live-only recordings are adopted on library load when they have no existing transcript, speaker assignments, or pending request. A saved adoption marker prevents later deliberate clearing from restoring the text again. Transcription failure, unavailable live recognition, or a disabled live setting must not prevent audio recording or saving.

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

The initial integration passed 261 tests, formatting, lint, and Preview packaging. Synthetic Preview checks covered live text in Transcript, independent recording settings, retaining final text when live recognition is turned off, saving editable text on stop, the zero-provider action, and the dependent Defaults layout. Further provider-count, narrow-window, appearance, and highlighting checks are tracked in the workflow worklogs. Validation uses synthetic Preview data and isolated tests without hardware capture or provider uploads.
