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

- Full app: `.build/macos/Gday Meetings.app`
- UI Preview: `.build/preview/Gday Meetings UI Preview.app`

These paths are relative to this client directory. Quit the bundle being rebuilt first. Preview packaging currently also rebuilds the full `.build/macos` bundle, so that development copy must be stopped too. A full app running from Applications or `.build/installer` can remain open while building Preview.

## Build and install

The app runs on macOS 14.2 or later. Building from source requires Apple's Command Line Tools or Xcode with Swift 6.2 and macOS SDK 26 or later. The build Mac must support those developer tools. Install current Command Line Tools for your macOS version; tests use Swift Testing.

```sh
xcode-select --install
# Wait for Apple's installer to finish, then from the repository root:
make install-macos
```

Finder opens `apps/client-macos-swift/.build/installer/` in icon view, with the app on the left, an **Applications** shortcut on the right, and a background showing drag instructions. Drag **Gday Meetings.app** onto Applications and open it. macOS may ask to allow Finder automation. If automation is unavailable, the folder opens normally; press Command-1 to show icons. Installation does not overwrite Applications automatically. No Rust, CMake, Homebrew, Node, Python, Docker, Apple Developer account, or full Xcode is needed. The app is locally ad-hoc signed; these scripts do not produce a notarized public release.

Other commands:

```sh
make doctor-macos    # Show the selected developer tools, Swift and SDK
make build-macos     # Build and sign the full app without opening Finder
make start-macos     # Build and launch the full app
make test-macos      # Run persistence, import and service contract tests
```

The first build compiles the pinned audio libraries from source archives included in the repository; later builds reuse them. This step needs no internet or separate package manager. See [audio dependency versions, licenses, and upgrades](ThirdParty/README.md).

Builds target the current Mac's architecture. Quit the development or staged app before rebuilding its bundle. The original Rust client retains `make install`, `make start`, and `make test-client`.

### Release build checks

GitHub Actions builds and ad-hoc signs the release app when a push or pull
request changes files under `apps/client-macos-swift/`, with parallel Apple
Silicon jobs for macOS 15, macOS 26, and macOS 27. Manual runs remain available.
The macOS 27 job uses GitHub's `xcode-27` preview runner. Apple moved from
macOS 15 to 26; there is no macOS 25 runner. Each job records the OS, architecture,
developer directory, Swift compiler, and SDK versions before building from a
fresh checkout. A failed job does not cancel the other builds.

The workflow is `.github/workflows/macos-build.yml`; its build steps are in
`.github/actions/build-macos/action.yml`. These checks validate compilation,
packaging, and signing, not recording permissions or audio hardware. They use
Xcode 26.0.1 on macOS 15 and the runner's default Xcode on macOS 26 and 27.
They do not cover every supported compiler version or Intel Macs.
Run `make build-macos` locally before finishing Swift changes;
use an isolated checkout if a development bundle is running.

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
- Start a recording while transcription, summaries, chat, or archiving continue. Open **Tasks** from the sidebar or bottom status to inspect progress, manage queued work, and return to each meeting. Up to two transcriptions and one summary run concurrently; additional requests wait in the queue. The app prevents duplicate requests for the same operation and waits for a meeting’s tasks to finish before allowing deletion or conflicting track imports.
- Drop audio/video files onto the meetings list to create one meeting per file. Drop files onto a meeting detail to add separate tracks; imported tracks start together at time zero. Originals are copied, and a failed batch is rolled back. Finish recording or a pending transcription before changing tracks. Importing never automatically transcribes or uploads.
- Play all tracks together or individual tracks in the persistent player. Continue browsing, searching, and editing other meetings while listening; use 15-second skips, speed selection, the scrubber, or transcript timestamps. Starting a recording pauses playback; it resumes only when you choose Play.
- Space toggles playback in the library window, except while editing text or using a sheet. Dragging any waveform previews the same time across the mix and individual tracks; release to seek all tracks together.
- Waveforms are cached locally and load independently of playback. Long-file overviews sample up to 1,024 frames per time bucket (1,200 buckets), so brief sounds between samples may be absent. Cached envelopes can appear while audio is still preparing. Playback does not wait for waveform generation. Ogg Opus decodes incrementally with libopusfile; native formats use incremental AVAudioFile reads. All tracks share one AVAudioEngine clock and a fixed-size buffer, with no whole-recording PCM conversion.
- Edit transcripts and action items. Summary displays selectable, read-only Markdown with the same rendering as Notes. Write Markdown notes with the **Format** menu, paste or drop images, and resize them from the bottom-right corner or with **Image Width…**. Originals stay in the meeting’s assets folder. Choose **Read** to view rendered notes and tables. New lines receive a time while recording or playing the selected meeting; appending after a 15-second pause adds a phrase time. Click a gutter time or press Command-Return to play from three seconds earlier. Notes are saved in `notes.md`; external edits reload when there is no pending app edit, and conflicting disk copies are preserved. Library format 4 adds images and phrase timing after format 3 moved notes out of the index. Upgrades keep a metadata backup, and older clients open newer libraries read-only.
- Assign multiple tags in meeting details. In **Transcript → Speakers**, assign each recognized voice to a person, or change or remove an automatic match. Manual assignments save RunPod voice samples for matching people in later transcripts from the same endpoint. Chat using person or tag context, or use **Agents** to launch an agent from the library folder.
- Assign tags in person details as well. In **Tags**, select a tag and turn on **Excluded** to hide meetings and people with that tag from the main lists and meeting search. Tags remain available for reversing exclusion, and **People → Show Excluded** reveals hidden people for editing. Person exclusion uses the person's own tags, not tags on meetings they attended.
- Set the language when creating a meeting, and edit it in the meeting's recording settings. **Settings → General → Transcription Language** supplies the initial value for new meetings and starts as English. Changing it leaves existing meetings unchanged. Language choices are the app’s standard offline list, independent of the selected provider. Providers map those choices to supported codes before uploading audio or starting live recognition. This Mac uses the US English model; Chinese Simplified and Traditional remain separate choices. RunPod uses its built-in worker list. A Gday Meetings website uses its saved language list or loads one on an explicit transcription request; **Load Languages** in its provider panel refreshes that list. An unsupported language stops transcription without changing the meeting or uploading audio. Each attempt retains both the meeting language and its resolved provider code.
- Add connections in **Settings → Service Providers**. Each provider has its own address, authentication, capabilities, and connection status. Choose the provider for each capability in **Settings → General**. Summaries and chat use an OpenAI-compatible language-model provider. Its **Model** field lists the endpoint's models once the endpoint URL and API key are entered; type to filter the menu, or type any model name.
- Export meeting text as JSON, Markdown, or TextBundle. Markdown and JSON exports include referenced images in a sibling assets folder; keep it beside the exported file. JSON retains time markers and an image manifest so importing it restores the image files. Older JSON files without a manifest import text and report missing images. TextBundle packages Markdown and assets together. Audio is not included. Copy recordings from the Rust client's library using **File → Import Existing Gday Library**.
- Use **Meeting Actions → Archive to Server** to retain a verified snapshot of a local meeting and its audio on a configured Gday Meetings website.
- Use the menu bar's **Start Recording** to record immediately with saved settings. Hold **Option** to reveal **New Recording…** and configure the session first (on macOS 14, Option-click **Start Recording**). Use **Command-N** for New Recording, **Command-O** for audio import, **Command-Shift-R** for recording, and **Command-comma** for Settings.

Website transcription checkpoints its upload inputs, stable attempt key, and task ID locally. If the app exits or a request fails, choose **Resume Transcription** to check the same durable job. The server and worker run separately; installing this client does not install them. A working server must have a worker configured before it can transcribe.

Tasks retains queued requests and task history in `tasks.jsonl` in the library folder. Each state change appends a record instead of rewriting the entire history. Rows appear newest first and retain their identity across retries. On launch and wake, queued work and interrupted transcription polls recover automatically when safe. An uncertain submission without a remote job ID requires checking the provider; an interrupted summary requires explicit retry because the provider may already have processed it. **Restart** is available when a saved remote transcription job is missing. **Dismiss** clears that task's pending transcription state as well as its row. **Run Next** changes queue priority without interrupting active work. **Stop Waiting** stops local waiting; the provider may continue processing. The former `managed-tasks.json` is not imported.

The RunPod provider uses the audio worker's URL-based job API. Its endpoint and API key are entered in its provider panel; there is no default endpoint. Select a configured **Filedrop** provider as the RunPod audio upload destination. Transcription sends the selected recording to Filedrop, then passes its temporary download URL to RunPod. Anyone with that link can download the audio until it expires. The provider panels explain upload destinations, link expiry, and applicable RunPod charges. Once configured, **Transcribe** starts uploading and processing in one click, without another confirmation dialog. Website uploads accept up to 500 MB, subject to the website's configured lower limit. The client converts unsupported native audio containers and large PCM tracks to M4A for server upload. AI requests send the selected context to the provider configured in Settings.

**Settings → General → After Recording → Automatically Summarize** generates a summary when a saved live transcript or provider transcription becomes available. Adding the first healthy summarization provider enables it; you can turn it off independently. If both arrive, each can generate a summary; a newer transcript waits when a summary is already running. Each **OpenAI-Compatible LLM** provider has a **Summary Prompt**, initially matching the Rust client’s structured summary instructions. Edit it in **Settings → Service Providers**, or choose **Restore Default**. Customized instructions from the former Defaults field move to the selected summary provider.

Summaries stream into the Markdown panel as they arrive. A failed or stopped stream preserves the previous saved summary. **Automatically Extract To-Dos**, initially on, controls whether a completed summary adds its action items to To-Dos.

Server archives are immutable snapshots. Repeating an archive resumes or verifies the original snapshot; it does not synchronize later edits. Local audio is retained. The meeting header shows **Archived on** the server name and date after the server verifies the archive, or **Archive incomplete** with **Archive to Server** to resume. The meetings list shows the same state as a cloud symbol.

### Agents

**Agents** in the sidebar renders the library folder’s saved `AGENTS.md` with the same Markdown reader as Summary. The app creates this guide on startup only when it is missing, with a detailed Swift file map, search examples, data interpretation guidance, and example launch commands for Codex and Claude Code. The guide can be used with other compatible agents. Existing guides are preserved, and navigating to Agents reloads edits made on disk. Code blocks have a **Copy Code** button. Opening Agents does not launch an agent or send meeting content.

### Service provider contracts

The [protocol index](../../docs/protocols/README.md) defines common connection checks and links to each capability. Saving an enabled provider and opening its panel check its current connection without submitting meeting content. Disabled providers are not checked. A successful check confirms access to the checked route; transcription still depends on worker configuration and reachable audio. Filedrop checks health, limits, and the API key. Its credential probe sends an empty request that is rejected before a file is created. See the [file-transfer contract](../../docs/protocols/file-transfer.md).

### On-device live transcription

**This Mac** provides Live Transcription on macOS 26 and later when Apple supports the device and language. **Settings → General → Recording → Automatically Transcribe** is on by default. During recording, the **Transcribe** switch stops or resumes transcription without stopping audio capture. Speech models download from Apple when needed; **Settings → Service Providers → This Mac** lists installed and available models. Audio is processed locally. macOS 14.2 and 15 keep recording and after-meeting transcription with a live-transcript availability message.

The recording card keeps the date, timer, stop action, and source meters visible. Open **Recording Settings** to change Language, Voice Processing, or Tags; the folded row summarizes their current values. Changing language restarts live recognition from that point and keeps earlier finalized text.

The **Transcript** tab shows live text while recording. When recording stops, finalized live text becomes the editable transcript if no existing transcript or pending transcription job would be replaced. It is then available to summaries, search, and export. Use **Re-transcribe with** to choose an eligible provider, or **Transcript History** to restore live text or an earlier revision. Replacing a transcript preserves its text and speaker identities. Live checkpoints and revisions are private per-meeting JSON files included when copying the library; normal transcript export contains the current editable transcript. Live text may be incomplete and recognition accuracy varies; runtime locale support does not establish bilingual accuracy.

To test the actual Apple engine with generated English and Mandarin speech (no microphone capture or cloud transcription), run `GDAY_APPLE_LIVE_TEST=1 make test-macos`. This can install Apple speech models. The opt-in test feeds both sources at wall-clock pace and checks final text and timing. It is an integration check, not a representative accuracy benchmark. See the [design and remaining gates](../../docs/design/live-transcription-research.md).

### Optional live provider test

`ProviderLiveTests` exercises the Filedrop upload and RunPod transcription flow with generated speech in an isolated temporary library. Ordinary test runs skip it. To run it deliberately, provide a local, untracked `.env` in this app directory containing `RUNPOD_ENDPOINT_URL`, `RUNPOD_API_KEY`, `FILE_DROP_URL`, and `FILE_DROP_API_KEY`, then run from the repository root:

```sh
GDAY_PROVIDER_LIVE_TEST=1 make test-macos
```

This test uploads synthetic speech and submits a billed RunPod job. It checks connection responses, local audio import, conversion, upload, transcription text, timestamps, and local file preservation. It does not test speaker-label accuracy or the Settings UI. The app does not load `.env` during normal use; credentials are entered in Service Providers. Do not commit the test credential file or include its values in logs.

### Differences from the Rust client

The native client currently supports one active recording with the default or a selected microphone and system audio. It saves separate source tracks as Opus (default), M4A/AAC, or WAV. It does not offer MP3 recording or concurrent recording sessions. It has no local REST/WebSocket server or Claude Code subprocess provider. Existing-library import copies supported meeting content, tags, speaker assignments, and confirmed voice samples. Imported samples remain separate from RunPod matching because their model provenance is unknown. Imported speaker assignments remain assigned to their people. Legacy chat history and arbitrary sidecars are not migrated. The Rust client remains available for those workflows.

## Audio quality

Apple voice processing (echo cancellation, noise suppression, and automatic gain control) is controlled by **Settings → General → Automatically Process Microphone Audio**, which is on by default. It turns processing on when the Mac’s default output reports a speaker, or when the microphone picks up system audio during a recording. Headphones and unidentified routes start unprocessed. The **Voice Processing** switch under the Microphone meter changes it for the rest of a recording. Processing can lower other apps' playback volume. The implementation requests minimum ducking, never monitors the microphone through speakers, and saves system audio separately. Echo removal depends on the device route; headphones provide the most reliable acoustic separation. Voice processing cannot guarantee echo-free recordings from every third-party calling app. New Recording can also select a specific microphone instead of the system default.

The audio pipeline aligns track timestamps to a shared host-clock timeline and preserves gaps with silence. Settings → General selects Opus (default), M4A/AAC, or WAV. Opus encodes continuously on a bounded background writer using bundled libopus, speech tuning, and DTX at 32 kbps per track. Stop drains pending audio and finishes the file; Opus recording does not create a whole-meeting WAV copy. WAV writes directly, while M4A converts temporary WAV sources after stopping and retains them if conversion fails. Playback uses bundled, statically linked Xiph libraries and AVAudioEngine; users install no extra runtime libraries. Recording continues through device and format changes; gaps are saved as silence. Effective processing, devices, sample rates, and channel counts, including every change during recording, are retained in the meeting's recording profile. Transcription uses compatible copies when needed; it does not replace the saved recording. See [audio research, design decisions, and hardware validation matrix](docs/AUDIO_DESIGN.md).

## Recording permissions and storage

When recording begins, macOS requests the microphone and system-audio permissions needed by the selected sources. System audio uses an audio-only Core Audio process tap: there is no display selection, screen-sharing session, or video capture. The packaged app includes `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription`. Permission decisions belong to macOS; previously denied access may require the user to change the existing decision in Privacy & Security. A recording needs at least one enabled audio source. Each session creates and tears down its own private tap and aggregate device, and saves microphone and system tracks separately.

The default meetings library lives in `~/.local/share/com.gdaymeetings.macos/`, and the app identity is `com.gdaymeetings.macos`, based on our domain `gdaymeetings.com`. The toolbar folder button opens this directory. Settings → Data shows its location, index size, rebuilding progress, and record counts. The Rust client uses its own directory and format. Provider keys are stored in Keychain. Back up the authoritative files, including recordings. Before 1.0, development-format changes use a temporary migration script while the app is stopped; the app contains no old-library migration path.

**Settings → Data → Change Folder…** can select another folder, including a dedicated folder in iCloud Drive. An empty destination offers **Copy Library**: copying runs off the main thread, verifies files, and keeps the originals. An existing library offers **Use Library** without merging it with the current one. Recording and active jobs must finish first. Editing pauses during the copy and while the new location awaits restart. After success, quit and reopen the app, or choose **Cancel Change** to keep using the original library. Cancel Change leaves a completed copy on disk. A missing or unreadable selected folder leaves the app read-only; reconnect it or choose an existing library in Data settings.

Downloaded models are stored in `LocalModels/` inside the data folder and are included when you copy the library. On first use, an absent model folder is populated from the previous Application Support location without deleting the original files. An existing model folder is preserved. Models are verified before use.

For a custom data folder, the disposable `index.db` and file-event cursor stay on this Mac under `~/Library/Caches/com.gdaymeetings.macos/libraries/<path hash>/`. Settings displays that index path. Cloud services sync the authoritative files, not the app's live SQLite database. Keep an iCloud folder downloaded and use the library on one Mac at a time; concurrent cloud edits are not merged automatically. Stop external edits and let synchronization finish before copying. The folder preference is stored outside the library, using a bookmark so the app can resolve a moved folder.

New meetings use `meetings/YYYYMMDD_<base36 ID>/`, with the meeting date in the local time zone. Existing folder names and meeting IDs stay unchanged; both folder formats are readable. Each folder contains separate `metadata.json`, `content.json`, `transcript.jsonl`, `summary.md`, and `notes.md` files. People and tags have independent JSON files in their respective directories. `index.db` is a disposable metadata, relationship, and search index; rebuilding it reads the authoritative files. Meetings queries 20 metadata rows per page and prefetches more pages in the background before the visible rows reach an edge. A native list preserves the visible meeting and pixel offset while rotating an 800-row window, with room for one in-flight batch. Full content loads on demand. A bounded payload cache protects active work. A document journal recovers interrupted saves. Provider metadata lives in `providers/<provider UUID>/models.json` and `languages.json`; provider IDs remain stable when names change.

`transcript.jsonl` holds one timed display segment per line. During recording, `transcript-checkpoint.json` commits saved rows and the recent replaceable tail. Before opening older development libraries, stop the previous app, back up the library, and run the verified migration described in the [canonical transcript worklog](../../docs/worklogs/2026-10-03-canonical-transcript-jsonl.md).

For independent UI checks, use `make start-macos-preview`. `GDAY_SWIFT_DATA_DIR` is only a library-location override for development: it does not enable UI Preview, disable recording/network access, or suppress all credential access (server authentication can still read Keychain). Tests use temporary directories and synthetic data. Folder choices made in Preview or with an explicit development data root remain in memory and do not change the regular app’s saved folder.

## Data privacy and logs

**Settings → Data Privacy** lists each type of data the app manages: recorded audio, meeting details, notes, transcripts, summaries, to-dos, chat messages, people and tags, local voice samples, credentials, settings, and logs. For each type, it shows its storage location or the provider and host that receive it, and the action that sends it. File storage is labeled **Saved in Data Folder**; credentials remain in this Mac’s Keychain and logs remain on this Mac. If the data folder is synced, its cloud service controls synchronization independently of these provider actions. The list is derived from the current service providers and settings (`Core/DataPrivacy.swift`). Opening the tab reads no credentials and makes no network requests.

| Data | Sent when | Receiver |
| --- | --- | --- |
| Recorded audio, meeting language | **Transcribe**, or after recording when **Automatically Transcribe** applies. Existing live text skips automatic transcription unless its override is on | Filedrop stores the audio; RunPod downloads it and receives the language. The website receives audio, title, and language. |
| Title, date, duration, language, notes, transcript, participant names and notes, Summary Prompt | **Generate Summary**, or after a transcript is saved when **Automatically Summarize** is on | The selected OpenAI-compatible provider. Existing summary and to-dos are not sent. |
| Meeting, person, or tag context, including existing summaries and chat | **Send** in a chat | The selected OpenAI-compatible provider. To-dos are not sent. |
| Meeting content, audio, notes images, linked people and tags (excluding voice samples) | **Archive to Server** | The signed-in Gday Meetings website. Older servers archive text and audio with a warning that images were omitted. Text and encoded images must fit the server's 20 MiB request limit. |
| API keys and sign-in tokens (Keychain) | Each request above; free connection checks and model lists when an enabled provider's panel opens; **Load Languages** for a website | Only the provider they belong to. A disabled provider is contacted only to list models while its endpoint or key is edited. |

Voice samples remain in the data folder and can therefore be synchronized by its cloud service. JSON and Markdown text exports omit voice vectors; website archives omit vectors and voice samples. Only manual assignments save training samples; automatic matches do not add samples. RunPod does not report an embedding model version, so matching is restricted to the same endpoint and vector size. A worker model change at the same endpoint can make older samples incompatible. Model provenance and a dedicated sample-reset control remain follow-up work; any match can be changed in Transcript → Speakers.

Every outbound request is logged in the `network` category of the unified log with the provider, host and path, data category, bytes sent, and outcome. Entries never include bodies, headers, query strings, credentials, or local file paths (`Services/NetworkLog.swift`).

Choose **Help → Follow Logs** to open Console. Select your Mac, click **Start**, and filter by subsystem `com.gdaymeetings.macos` (`com.gdaymeetings.macos.preview` for UI Preview). Enable **Action → Include Info Messages** to include informational entries. Console manages streaming and saved searches; the app does not set the filter automatically.

Choose **Help → Export Logs**, or **Export Logs** in Data Privacy, to save the last hour of this app run's logs to `~/Library/Logs/Gday Meetings/` and show the file in Finder. The logs contain device names, formats, recovery decisions, and network transmission records, but no audio or meeting text. For terminal commands and logs from earlier app runs, see [Recording diagnostics](docs/AUDIO_DESIGN.md#recording-diagnostics).

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
