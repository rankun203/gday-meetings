---
title: Swift macOS client
date: 2026-09-26
status: active
scope: swift-app
---

# Gday Meetings — SwiftUI client

A native macOS meeting app built with SwiftUI, AppKit, AVFoundation, Core Audio, Security, and Foundation. Ogg Opus playback uses statically linked libopusfile, libopus, and libogg and does not launch the Rust client or a browser UI.

## Choose a run mode

The same SwiftUI client supports two explicit modes. Commands below run from the repository root.

| | Full app (default) | UI Preview |
| --- | --- | --- |
| Build only | `make build-macos` | `make build-macos-preview` |
| Build and launch | `make start-macos` | `make start-macos-preview` |
| Library | Your persistent meetings library | Fresh temporary library with synthetic recordings |
| Credentials | Reads saved API keys and sign-in tokens from Keychain; macOS may prompt | No Keychain access; enter test credentials or load them explicitly into memory |
| Audio | Real playback and recording | Silent playback; recording disabled |
| Online services | Configured transcription, AI, and server services available | Real provider checks and jobs with configured test credentials |
| Purpose | Normal use and coordinated hardware/service testing | UI and service-flow testing with an isolated library |

UI Preview displays a visible banner and offers System/Light/Dark appearance controls. Use it for UI validation and provider testing without Keychain prompts or audio hardware. Provider actions can use the network and upload selected content. It does not validate capture permissions or audible output. See [UI Preview details and signing](docs/UI_PREVIEW.md).

Build outputs:

- Full app: `.build/macos/Gday Meetings Swift.app`
- UI Preview: `.build/preview/Gday Meetings UI Preview.app`

These paths are relative to this client directory. Quit the bundle being rebuilt first. Preview packaging currently also rebuilds the full `.build/macos` bundle, so that development copy must be stopped too. A full app running from Applications or `.build/installer` can remain open while building Preview.

## Build and install

Requires macOS 14.2 or later and Apple's Command Line Tools with Swift 5.9 or later. Install current Command Line Tools for your macOS version; tests use Swift Testing and require Swift 6 or later.

```sh
xcode-select --install
# Wait for Apple's installer to finish, then from the repository root:
make install-macos
```

Finder opens `apps/client-macos-swift/.build/installer/` in icon view, with the app on the left, an **Applications** shortcut on the right, and a background showing drag instructions. Drag **Gday Meetings Swift.app** onto Applications and open it. macOS may ask to allow Finder automation. If automation is unavailable, the folder opens normally; press Command-1 to show icons. Installation does not overwrite Applications automatically. No Rust, CMake, Homebrew, Node, Python, Docker, Apple Developer account, or full Xcode is needed. The app is locally ad-hoc signed; these scripts do not produce a notarized public release.

Other commands:

```sh
make doctor-macos    # Show the selected developer tools, Swift and SDK
make build-macos     # Build and sign the full app without opening Finder
make start-macos     # Build and launch the full app
make test-macos      # Run persistence, import and service contract tests
```

The first build compiles the pinned audio libraries from source archives included in the repository; later builds reuse them. This step needs no internet or separate package manager. See [audio dependency versions, licenses, and upgrades](ThirdParty/README.md).

Builds target the current Mac's architecture. Quit the development or staged app before rebuilding its bundle. The original Rust client retains `make install`, `make start`, and `make test-client`.

### Swift formatting

Run `make format-macos` before committing Swift changes and `make lint-macos`
to check them without modifying files. Both use Apple's `xcrun swift-format`
with the checked-in `.swift-format`: four-space indentation, a 120-column target,
ordered imports, and one statement per line. Refactoring and API-policy rules
are disabled; formatting does not replace code review or tests. Keep the
`swift-tools-version` directive on the first line of `Package.swift`, separated
from imports by a blank line.

The commands cover the package manifest, app sources, and tests. They exclude
vendored sources and build output; C bridges are outside Swift formatter scope.
Formatting checks run locally; there is no dedicated formatting CI workflow.
Formatter output can change with Apple toolchain updates; review any new baseline
in a separate formatting commit. Use current Command Line Tools if `swift-format`
is unavailable. No Homebrew formatter is required, and normal build/install
commands do not run or require formatting tools.

### With Xcode

Run `bash apps/client-macos-swift/scripts/build-audio-dependencies.sh` once from the repository root, then open `Package.swift` in Xcode and select the **GdayMeetings** executable scheme to build and debug. No generated `.xcodeproj` is needed. To run with the microphone/system-audio purpose strings and stable app identity, use `make start-macos` to launch the packaged app; Xcode can attach to its `GdayMeetings` process. The same Make commands work with Xcode selected through `xcode-select` or `DEVELOPER_DIR`. For UI Preview when running the executable from Xcode, add `--ui-preview` to the scheme’s launch arguments; remove it to return to full mode. The packaged Preview target additionally uses a separate bundle identifier to isolate window/preferences state.

## Native workflows

- Search your local meeting titles, notes, summaries and transcripts.
- Choose **New Recording** to name the meeting and select microphone/system sources. During capture, take notes beside real source meters, an elapsed timer, and **Stop & Save**. Recording controls remain available when browsing elsewhere.
- Start a recording while transcription, summaries, chat, or archiving continue. Progress identifies the meeting being processed. The app prevents duplicate requests for the same operation and waits for a meeting’s tasks to finish before allowing deletion or conflicting track imports.
- Drop audio/video files onto the meetings list to create one meeting per file. Drop files onto a meeting detail to add separate tracks; imported tracks start together at time zero. Originals are copied, and a failed batch is rolled back. Finish recording or a pending transcription before changing tracks. Importing never automatically transcribes or uploads.
- Play all tracks together or individual tracks in the persistent player. Continue browsing, searching, and editing other meetings while listening; use 15-second skips, speed selection, the scrubber, or transcript timestamps. Starting a recording pauses playback; it resumes only when you choose Play.
- Space toggles playback in the library window, except while editing text or using a sheet. Dragging any waveform previews the same time across the mix and individual tracks; release to seek all tracks together.
- Waveforms are cached locally and load independently of playback. Long-file overviews sample up to 1,024 frames per time bucket (1,200 buckets), so brief sounds between samples may be absent. Cached envelopes can appear while audio is still preparing. Playback does not wait for waveform generation. Ogg Opus decodes incrementally with libopusfile; native formats use incremental AVAudioFile reads. All tracks share one AVAudioEngine clock and a fixed-size buffer, with no whole-recording PCM conversion.
- Edit transcripts and generate or edit summaries and action items. Write Markdown notes with the **Format** menu. New note lines receive a time while recording or playing the selected meeting; click a gutter time or press Command-Return to play from three seconds earlier. Notes are saved in each meeting’s `notes.md` file. Library format 3 moves existing notes there and keeps an index backup. JSON exports retain time markers; Markdown exports show readable times. Image attachments are planned for a later phase.
- Assign multiple tags in meeting details. In **Transcript → Speakers**, assign each recognized voice to a person, or confirm, reject, or change a suggested match. Confirmed RunPod voice samples help suggest people in later transcripts from the same endpoint. Chat using meeting, person, or tag context.
- Set the language when creating a meeting, and edit it in the meeting's recording settings. **Settings → Defaults → Default Language** supplies the initial value for new meetings and starts as English. Changing it leaves existing meetings unchanged. Language choices are the app’s standard offline list, independent of the selected provider. Providers map those choices to supported codes before uploading audio or starting live recognition. This Mac uses the US English model; Chinese Simplified and Traditional remain separate choices. RunPod uses its built-in worker list. A Gday Meetings website uses its saved language list or loads one on an explicit transcription request; **Load Languages** in its provider panel refreshes that list. An unsupported language stops transcription without changing the meeting or uploading audio. Each attempt retains both the meeting language and its resolved provider code.
- Add connections in **Settings → Service Providers**. Each provider has its own address, authentication, capabilities, and connection status. Choose the provider for each capability in **Settings → Defaults**. Summaries and chat use an OpenAI-compatible language-model provider. Its **Model** field lists the endpoint's models once the endpoint URL and API key are entered; type to filter the menu, or type any model name.
- Export meeting text as JSON or Markdown, import text archives, or copy recordings from the Rust client's library using **File → Import Existing Gday Library**. JSON text exports do not embed audio.
- Use **Meeting Actions → Archive to Server** to retain a verified snapshot of a local meeting and its audio on a configured Gday Meetings website.
- Use the menu bar's **Start Recording** to record immediately with saved settings. Hold **Option** to reveal **New Recording…** and configure the session first (on macOS 14, Option-click **Start Recording**). Use **Command-N** for a meeting, **Command-O** for audio import, **Command-Shift-R** for recording, and **Command-comma** for Settings.

Website transcription checkpoints its upload inputs, stable attempt key, and task ID locally. If the app exits or a request fails, choose **Resume Transcription** to check the same durable job. The server and worker run separately; installing this client does not install them. A working server must have a worker configured before it can transcribe.

The RunPod provider uses the audio worker's URL-based job API. Its endpoint and API key are entered in its provider panel; there is no default endpoint. Select a configured **Filedrop** provider as the RunPod audio upload destination. Transcription sends the selected recording to Filedrop, then passes its temporary download URL to RunPod. Anyone with that link can download the audio until it expires. The provider panels explain upload destinations, link expiry, and applicable RunPod charges. Once configured, **Transcribe** starts uploading and processing in one click, without another confirmation dialog. Website uploads accept up to 500 MB, subject to the website's configured lower limit. The client converts unsupported native audio containers and large PCM tracks to M4A for server upload. AI requests send the selected context to the provider configured in Settings.

Server archives are immutable snapshots. Repeating an archive resumes or verifies the original snapshot; it does not synchronize later edits. Local audio is retained. The meeting header shows **Archived on** the server name and date after the server verifies the archive, or **Archive incomplete** with **Archive to Server** to resume. The meetings list shows the same state as a cloud symbol.

### Service provider contracts

The [protocol index](../../docs/protocols/README.md) defines common connection checks and links to each capability. Saving an enabled provider and opening its panel check its current connection without submitting meeting content. Disabled providers are not checked. A successful check confirms access to the checked route; transcription still depends on worker configuration and reachable audio. Filedrop checks health, limits, and the API key. Its credential probe sends an empty request that is rejected before a file is created. See the [file-transfer contract](../../docs/protocols/file-transfer.md).

### On-device live transcription

**This Mac** provides Live Transcription on macOS 26 and later when Apple supports the device and language. **Settings → Defaults → Show Live Transcript** is on by default. During recording, the **Live Transcript** switch stops or resumes recognition without stopping audio capture. Speech models download from Apple when needed; **Settings → Service Providers → This Mac** lists installed and available models. Audio is processed locally. macOS 14.2 and 15 keep recording and after-meeting transcription with a live-transcript availability message.

The recording card keeps the date, timer, stop action, and source meters visible. Open **Recording Settings** to change Language, Voice Processing, or Tags; the folded row summarizes their current values. Changing language restarts live recognition from that point and keeps earlier finalized text.

The Transcript tab retains a separate **Live Draft · This Mac**. Choose **Use Live Draft as Transcript** to edit it and use it in summaries and search. Replacing a transcript saves its text and speaker identities under **Saved Transcript Revisions**. Live drafts and revisions are private per-meeting JSON files included when copying the library; the normal transcript export contains the selected editable transcript. Live drafts may be incomplete and recognition accuracy varies; runtime locale support does not establish bilingual accuracy.

To test the actual Apple engine with generated English and Mandarin speech (no microphone capture or cloud transcription), run `GDAY_APPLE_LIVE_TEST=1 make test-macos`. This can install Apple speech models. The opt-in test feeds both sources at wall-clock pace and checks final text and timing. It is an integration check, not a representative accuracy benchmark. See the [design and remaining gates](../../docs/design/live-transcription-research.md).

### Optional live provider test

`ProviderLiveTests` exercises the Filedrop upload and RunPod transcription flow with generated speech in an isolated temporary library. Ordinary test runs skip it. To run it deliberately, provide a local, untracked `.env` in this app directory containing `RUNPOD_ENDPOINT_URL`, `RUNPOD_API_KEY`, `FILE_DROP_URL`, and `FILE_DROP_API_KEY`, then run from the repository root:

```sh
GDAY_PROVIDER_LIVE_TEST=1 make test-macos
```

This test uploads synthetic speech and submits a billed RunPod job. It checks connection responses, local audio import, conversion, upload, transcription text, timestamps, and local file preservation. It does not test speaker-label accuracy or the Settings UI. The app does not load `.env` during normal use; credentials are entered in Service Providers. Do not commit the test credential file or include its values in logs.

### Differences from the Rust client

The native client currently supports one active recording with the default or a selected microphone and system audio. It saves separate source tracks as Opus (default), M4A/AAC, or WAV. It does not offer MP3 recording or concurrent recording sessions. It has no local REST/WebSocket server or Claude Code subprocess provider. Existing-library import copies supported meeting content, tags, speaker assignments, and confirmed voice samples. Imported samples remain separate from RunPod matching because their model provenance is unknown. An imported assignment remains a suggestion unless a saved confirmed sample establishes its confirmation. Legacy chat history and arbitrary sidecars are not migrated. The Rust client remains available for those workflows.

## Audio quality

Apple voice processing (echo cancellation, noise suppression, and automatic gain control) is controlled by **Settings → Defaults → Turn On Voice Processing Automatically**, which is on by default. It turns processing on when the Mac’s default output reports a speaker, or when the microphone picks up system audio during a recording. Headphones and unidentified routes start unprocessed. The **Voice Processing** switch under the Microphone meter changes it for the rest of a recording. Processing can lower other apps' playback volume. The implementation requests minimum ducking, never monitors the microphone through speakers, and saves system audio separately. Echo removal depends on the device route; headphones provide the most reliable acoustic separation. Voice processing cannot guarantee echo-free recordings from every third-party calling app. New Recording can also select a specific microphone instead of the system default.

The audio pipeline aligns track timestamps to a shared host-clock timeline, preserves gaps with silence, and uses bounded asynchronous PCM file writes during capture. Settings → Defaults selects Opus (default), M4A/AAC, or WAV. After stopping, each track is encoded separately; compressed-file metadata is saved before temporary WAV sources are removed. Conversion failure preserves the WAV recording. Opus encoding uses native Apple codecs and standard Ogg wrapping without FFmpeg. Playback uses bundled, statically linked Xiph libraries and AVAudioEngine; users install no extra runtime libraries. Recording continues through device and format changes; gaps are saved as silence. Effective processing, devices, sample rates, and channel counts, including every change during recording, are retained in the meeting's recording profile. Transcription uses compatible copies when needed; it does not replace the saved recording. See [audio research, design decisions, and hardware validation matrix](docs/AUDIO_DESIGN.md).

## Recording permissions and storage

When recording begins, macOS requests the microphone and system-audio permissions needed by the selected sources. System audio uses an audio-only Core Audio process tap: there is no display selection, screen-sharing session, or video capture. The packaged app includes `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription`. Permission decisions belong to macOS; previously denied access may require the user to change the existing decision in Privacy & Security. A recording needs at least one enabled audio source. Each session creates and tears down its own private tap and aggregate device, and saves microphone and system tracks separately.

The meetings library lives in `~/.local/share/com.gdaymeetings.macos/`, and the app identity is `com.gdaymeetings.macos`, based on our domain `gdaymeetings.com`. The toolbar folder button opens this directory. On first launch, if the new directory does not exist, the app copies the former `~/Library/Application Support/Gday Meetings Swift/` library into it, preserving the original. Existing destination libraries are never merged or overwritten. Quit older app versions before migration; changes subsequently made in an older version are not synchronized. The Rust client uses its own directory and format. Changing the bundle identity may require granting recording permissions again. OAuth credentials and provider keys are stored in Keychain. Keep a backup of the library to retain audio as well as text. `library.json` records a format version. The app opens its own version and older ones, keeping `library-v<N>-backup.json` before it upgrades an older library. A library saved by a newer version is shown read-only and is never rewritten; install the latest version to open it.

For independent UI checks, use `make start-macos-preview`. `GDAY_SWIFT_DATA_DIR` is only a library-location override for development: it does not enable UI Preview, disable recording/network access, or suppress all credential access (server authentication can still read Keychain). Tests use temporary directories and synthetic data.

## Data privacy and logs

**Settings → Data Privacy** lists each type of data the app manages: recorded audio, meeting details, notes, transcripts, summaries, to-dos, chat messages, people and tags, local voice samples, credentials, settings, and logs. For each type, it shows **Stays on this Mac** or the provider and host that receive it, and the action that sends it. The list is derived from the current service providers and settings (`Core/DataPrivacy.swift`). Opening the tab reads no credentials and makes no network requests.

| Data | Sent when | Receiver |
| --- | --- | --- |
| Recorded audio, meeting language | **Transcribe**, or after each recording with **Automatically Transcribe Recordings** on | Filedrop stores the audio; RunPod downloads it and receives the language. The website receives audio, title, and language. |
| Title, notes, transcript, summary, chat, Summary Instructions | **Generate Summary** or **Send** in a chat | The selected OpenAI-compatible provider. To-dos are not sent. |
| Meeting content, audio, linked people and tags (excluding voice samples) | **Archive to Server** | The signed-in Gday Meetings website. |
| API keys and sign-in tokens (Keychain) | Each request above; free connection checks and model lists when an enabled provider's panel opens; **Load Languages** for a website | Only the provider they belong to. A disabled provider is contacted only to list models while its endpoint or key is edited. |

Voice samples remain in the local library. JSON and Markdown text exports omit voice vectors; website archives omit vectors and voice samples. Only confirmed assignments train recognition. RunPod does not report an embedding model version, so matching is restricted to the same endpoint and vector size. A worker model change at the same endpoint can make older samples incompatible. Model provenance and a dedicated sample-reset control remain follow-up work; review suggested matches before confirming them.

Every outbound request is logged in the `network` category of the unified log with the provider, host and path, data category, bytes sent, and outcome. Entries never include bodies, headers, query strings, credentials, or local file paths (`Services/NetworkLog.swift`).

Choose **Help → Export Logs**, or **Export Logs** in Data Privacy, to save the last hour of this app run's logs to `~/Library/Logs/Gday Meetings/` and show the file in Finder. The logs contain device names, formats, recovery decisions, and network transmission records, but no audio or meeting text. To follow a recording live, or to read logs from an earlier app run, see [Recording diagnostics](docs/AUDIO_DESIGN.md#recording-diagnostics).

## Human Interface Guidelines

**Liquid Glass is the default design direction for all future UI changes.** Follow [UI_DESIGN.md](docs/UI_DESIGN.md) for appearance, interaction, accessibility, compatibility, and validation requirements. Apple Music's capsule tabs and soft sidebar selection are visual references; use supported native APIs and preserve older-macOS fallbacks. Existing views have not all been migrated yet.

The source cites the relevant Apple HIG principles beside the controls implementing them:

| Principle | Implementation |
| --- | --- |
| [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) | Native navigation split view with library, content selection, and detail panes. |
| [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Recording and contextual actions at the top of the window, labeled SF Symbols. |
| [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | Standard Settings scene with grouped recording, transcription, and intelligence options. |
| [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Native controls, semantic fonts/colors, accessible labels, keyboard navigation, and text selection. |
| [Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy) | Just-in-time recording permission requests, browser authentication, and Settings → Data Privacy. |
| [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) | Focused recording setup with draft choices, explicit start/cancel, and inline retry errors. |
| [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback) | Actual source levels and distinct recording/saving states without invented progress. |
| [Playing audio](https://developer.apple.com/design/human-interface-guidelines/playing-audio) | App-owned persistent transport; browsing never implicitly starts or replaces playback. |
| [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | Resizable windows, standard file panels, menu commands, and familiar keyboard shortcuts. |

`ViewState` is an alias of the original `SwiftUI.State` property wrapper. SDK 27 also declares a `State` macro whose plugin is absent from this Command Line Tools installation; the alias avoids that optional macro dependency without changing SwiftUI state behavior.
