---
title: UI Preview
date: 2026-09-26
status: active
scope: swift-app-testing
---

# UI Preview

From the repository root:

```sh
make build-macos-preview   # Build only
make start-macos-preview   # Build and launch
```

The bundle is `apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app`. The underlying build script remains `bash apps/client-macos-swift/scripts/preview-macos.sh`.

For full mode, use `make build-macos` or `make start-macos`; `make install-macos` stages the full app for installation. See the [mode comparison](../README.md#choose-a-run-mode). Quit Preview and the full `.build/macos` development copy before rebuilding Preview, because packaging reuses the full build. Copies running from Applications or `.build/installer` can remain open.

The preview banner identifies the mode and provides an Appearance selector for UI testing. Use audio files from Finder for manual drop checks: drop files into the meetings list to create separate meetings, or onto a meeting to add tracks. Generated `microphone.wav` and `system.wav` fixtures can be copied from the temporary preview library for this purpose.

This uses the production SwiftUI screens with a clearly marked preview banner, generated one- and two-track audio, a fresh temporary library on each launch, silent playback, and a local light/dark appearance selector. Keychain reads/writes and real recording are disabled; playback is silent. Online services remain available for connection checks and deliberately started provider jobs. Normal recordings and saved credentials are not loaded. Enter test credentials in Service Providers or load a test credential file explicitly. Temporary fixture libraries are left in the system temporary directory for inspection and normal OS cleanup. “Synthetic single track” shows **Archived on meetings.example.invalid** and “Synthetic conversation” shows **Archive incomplete**. These checkpoints are synthetic; Preview cannot sign in to a website, so **Archive to Server** stays disabled and nothing is uploaded.

The bundle flag `GdayUIPreview` enables this mode; developers can also launch the executable with `--ui-preview`. The separate preview bundle identifier isolates window/preferences state and lets the normal app remain open. Do not use preview results as evidence of real capture, permissions, or speaker output. A provider check validates its documented connection operation; a successful transcription test validates the tested service path. Neither establishes performance or accuracy for other recordings.

The synthetic conversation includes multiple tags and manually assigned, automatically matched, and unassigned speakers below its transcript. Use these fixtures to check tag menus, speaker assignment, reassignment, removal, and narrow-window layout. They test interaction and persistence, not recognition accuracy. The sidebar contains Meetings, People, Tags, and Tasks; providers are configured in Settings.

## Task queue

Launch the Preview executable with `--synthetic-tasks`, or set its `GdaySyntheticTasks` bundle flag, to add two running tasks, one queued transcription, a summary needing attention, an expired transcription, and one completed summary. These rows are synthetic and never submit provider work. The bottom status shows **2 Tasks Need Attention**, running and queued counts, and **Review 2 Tasks**. Choose that button or **Tasks** in the sidebar to open the full-width queue panel.

Check **Open Meeting**, **Run Next**, **Remove from Queue**, **Stop Waiting**, **Retry**, and **Dismiss**. Synthetic Retry completes locally; stopping or removing a synthetic task updates its state without cancelling a remote job. Run Next changes queue order but does not execute synthetic work. Verify that failed tasks appear first under **Needs Attention**, with newest-first order within each section. Check task counts, keyboard access, and action wrapping at narrow widths in light and dark appearance. Ordinary Preview launches have no synthetic tasks. Real provider tasks started deliberately in Preview use the production queue and can submit content.

Use `--synthetic-pagination` to add 45 older meetings, load the first 20, then scroll through later pages. Search for **Unique last-page search phrase** to find content outside the first page. Use `--synthetic-summary-stream` to display a synthetic summary draft that grows for about 32 seconds in Synthetic conversation. This fixture makes no network requests and does not replace the saved summary; transport streaming is tested separately with a loopback server.

## Long transcript

Launch with `--synthetic-long-transcript` to replace Synthetic conversation's transcript with 10,000 alternating short and wrapped segments. Scroll its Transcript tab and confirm timestamp/speaker alignment remains stable. Double-click text or choose **Edit Transcript** from its contextual menu to edit. Return or leaving the editor saves; Escape cancels. Only the active segment creates an editor. This synthetic fixture checks layout and editing; use the full app with an isolated real library for end-to-end CPU, memory, and perceived scrolling measurements.

## Provider testing

UI Preview uses the real provider adapters. Saving an enabled provider or opening its panel checks its connection without uploading meeting content. Meeting language pickers use the standard offline app list with or without a provider. RunPod's supported-code list is built in. A website's list loads when you choose **Load Languages** in its provider panel or explicitly transcribe without a saved list. Verify one English choice, separate Simplified and Traditional Chinese, Italian, and Cantonese; changing providers must not change these choices. Transcription and other content operations use the same actions as the full app. **Transcribe** starts the configured upload and job directly; provider panels contain the brief destination and charge details. Preview fixtures are synthetic by default; importing another recording does not automatically upload it.

To seed test providers without typing credentials, build Preview, then launch its executable with an explicit credential-file path:

```sh
"apps/client-macos-swift/.build/preview/Gday Meetings UI Preview.app/Contents/MacOS/GdayMeetings" \
  --provider-test-env "$PWD/apps/client-macos-swift/.env"
```

This option is for UI Preview. The file supplies `RUNPOD_ENDPOINT_URL`, `RUNPOD_API_KEY`, `FILE_DROP_URL`, and `FILE_DROP_API_KEY`. Credentials remain in memory; the app does not write them to Keychain or load this file during normal launches. Keep the file untracked. The seed creates RunPod and Filedrop providers, enables Transcription, Speaker Labeling, and File Transfer, links the upload provider, and selects RunPod for transcription. New meetings use **Settings → General → Transcription Language**, initially English (`en`); the provider seed does not set a language. Loading it makes no network requests and does not upload a recording. Saving provider settings later writes only non-secret settings into the temporary library.

To fill **Settings → Data Privacy** without credentials, launch the executable with `--synthetic-providers`. It adds RunPod, Filedrop, and OpenAI-compatible providers with `.invalid` addresses, selects them for transcription and summaries, and turns on **Automatically Transcribe**. `.invalid` names never resolve, so checks and model lists started by opening a provider panel fail on this Mac and nothing is uploaded. Website sign-in cannot be simulated; website rows are covered by unit tests.

Use `--synthetic-multiple-transcription-providers` to add a second eligible RunPod connection with an `.invalid` address. The saved Transcript action becomes a provider menu; inspect its choices without starting a job. The ordinary `--synthetic-providers` fixture shows the single-provider action, and no provider flag shows setup.

Connection checks use real services. Starting a RunPod transcription uploads the selected audio to the configured Filedrop provider and can incur RunPod charges. Use generated speech when validating recognition; the default waveform fixtures exercise layout and playback controls. See the [file-transfer contract](../../../docs/protocols/file-transfer.md) and the [optional live test](../README.md#optional-live-provider-test).

## Signing and repeated Keychain prompts

The production identifier remains `com.gdaymeetings.macos`. Default local builds use ad-hoc signing, whose designated requirement is tied to one build's code hash. Merely keeping the bundle identifier does not preserve Keychain trust across changed ad-hoc executables. See [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

To use an already installed signing certificate consistently, set `GDAY_CODESIGN_IDENTITY` to its identity or SHA-1 when building/installing. No certificate is created or imported automatically. A transition from an existing ad-hoc build may still need authorization. Existing credential access controls are not weakened. UI Preview requires no signing certificate and never accesses Keychain.

Normal settings saves now write credentials only when their values changed. The normal app still reads saved credentials at startup; this is not a promise of prompt-free production launches.

The collapsible **Recording visualization preview · synthetic levels** section shows the production microphone/system meters with simulated ten-second histories. Use it to check miniature waveform layout and appearance without starting capture. System Audio simulates a four-second device switch every 20 seconds: “Reconnecting system audio…” for two seconds, then “Switching system audio to Preview Headphones…”, with the reset meter throughout. The Microphone column also shows the live **Voice Processing** switch: Off shows the “Echo detected” hint, and On shows the “Echo detected · Voice Processing turned on” notice. The switch changes only the preview; no capture, device, or echo detection runs. The simulation does not exercise real device recovery. It is absent from the full app.

New Recording's microphone menu lists this Mac's real input devices. Listing devices reads Core Audio properties only; it opens no device and requests no permission.

## Markdown notes

The synthetic conversation has timed headings and list items, a task checkbox, and an untimed line in **Notes**. Click a gutter time or use **Playback → Play From Line** (Command-Return) to seek the silent player three seconds before the saved time. Check editing, undo, list continuation, Format commands, and keyboard access in light and dark appearance and at narrow widths. Marker comments stay hidden in the editor and remain in the temporary library's `notes.md`. Images are a later phase and currently remain Markdown text.

## Live transcription and recording card

The synthetic conversation includes a saved live checkpoint. Open its Transcript tab to check timeline playback, provider-specific re-transcription actions, and **Transcript History**. Restoring the live transcript keeps the previous text as a revision. Recognition accuracy is not simulated.

Launch Preview with `--synthetic-live-recording` to show the production recording card for the synthetic conversation. It includes 18 finalized phrases, a wrapped passage, two provisional phrases, and one assigned person. This flag does not open audio hardware, download a model, or start SpeechAnalyzer. Check the 32-point Recording Settings disclosure and folded language/processing/tag summary. Live text and its switch appear in the Transcript tab, with status and **Follow Live** above the text viewport. Settings and meters do not scroll with new text. The synthetic recording’s duration advances, but its audio files remain fixture audio.

Live and saved text use the same compact native table, timestamps, speaker badges, selection, and editing gestures. With Label Speakers off, `mic` and `sys` identify audio sources. Source badges have a filled background without a dotted outline and do not offer person assignment. With labeling on, words without a detected speaker continue under the previous speaker for that source; leading unidentified text has no badge. Provisional text has a subtle underline. Double-click text or choose **Edit Transcript** to correct it; Return or leaving the editor saves, and Escape cancels. Double-click a detected speaker’s badge or choose **Assign Person** to assign a person. Selecting a passage, opening its context menu, editing, opening the person picker, or scrolling stops following until **Follow Live** is selected again. Recognition refreshes wait while an editor or picker is open. Playback is unavailable during recording. Stop & Save adopts finalized and manually corrected text with its person assignments.

Use `--synthetic-live-speakers` for a three-minute evolving Chinese transcript fixture. It submits generic words, finalizes each phrase, and delivers delayed synthetic speaker activity. Every third chunk has no activity, and the identified speaker changes every six chunks. Check that text continues under the previous speaker during gaps, the initial unidentified text has no badge, and delayed activity corrects the recent speaker boundary. Scroll back to pause following, edit a passage while new words arrive, then select **Follow Live**. **Stop & Save** stops the replay and adopts its text; reopen the meeting to verify the same effective labels. No capture hardware or labeling model runs. This fixture measures application processing and UI behavior; it does not measure inference accuracy or inference resource usage.

The ordinary `--synthetic-live-recording` fixture does not simulate continuing recognition. Use the focused live-transcript tests to validate replacement, split/merge reconciliation, and preservation of manual changes. Preview checks layout and gestures, not recognition accuracy or real recording finalization.

## Local speaker provider settings

### General scenarios

Launch UI Preview with `--general-scenario=N`, where `N` is 1 through 10, to exercise General using synthetic provider health. The fixtures make no health requests, download no models, and start no inference. They cover ready providers, all features off, missing selections, missing files, checks in progress, an unhealthy dropdown alternative, different health across a provider's capabilities, an inconclusive server check, independent stage choices, and language/labeling dependencies. Open Settings → General after launch. Use Preview Scenario to switch fixtures without restarting. Provider repair actions remain real operations and are not part of these fixtures.

Compare feature on/off state with readiness, open a provider dropdown, and follow a warning to its provider settings. Scroll over either column and verify both move together. Check the After Recording controls below the initial viewport, long warnings, keyboard access, and light/dark appearance. These fixtures validate presentation; health concurrency, saved intent, and stale responses need separate automated tests.

### Provider controls

Launch with `--synthetic-local-speakers` to add Nemotron and Community-1 provider configurations and independent General selections. This flag does not download models or start inference. Open **Service Providers** and select either provider to inspect capability switches, preset selection, buffering delay, and model readiness. Nemotron offers every preset supported by the shared native runtime; the delay describes required audio buffering, not time to a correct speaker label.

In **General**, **Recording** and **After Recording** expose independent transcription, speaker labeling, and speaker association switches. Changing a switch in one stage must not change the other. Capability providers occupy the right column. Both columns share one scroll area. Provider warnings link to the affected provider’s settings.

Use **Download**, the cancel button, **Retry**, **Verify…**, and **Remove Download** only when deliberately testing installation. These controls use the real model manager and its app-managed model folder, even in Preview. **Open Model Folder** reveals the selected revision's directory. Expand **Manual Installation** for its required folder layout; after copying files, choose **Refresh**, then **Verify…**. A discovered folder must pass verification and preparation before it is ready. Removing a provider configuration keeps downloaded models.

The recording panel’s **Transcribe** and **Label Speakers** switches control processing for the current recording. Turning off Label Speakers stops speaker analysis even when General enables Speaker Association; turning it back on follows the recording’s association preference. During a synthetic recording it exercises controls and status without capture or inference. If a detected speaker identity exists, **Apply to This Speaker** in the person picker controls whether attribution affects linked passages or only the selected passage. Source placeholders cannot be assigned to a person. Previously assigned source passages keep their names; after saving, use **Speakers → Remove Assignment** to clear them.

Use `--synthetic-recording-start --synthetic-pagination` to add **Start Synthetic Recording** to the preview banner. Click it after the meeting list appears, both at the top and after scrolling to older meetings. It inserts a new synthetic meeting, selects it, and reveals its complete first row. **Stop & Save** ends the synthetic state so the check can be repeated. This exercises list insertion and recording presentation without audio capture or a provider request; generated fixture audio already exists when the recording state begins.
