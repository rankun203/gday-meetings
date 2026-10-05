---
title: Native audio design and validation
date: 2026-09-26
status: active
scope: swift-app-audio
---

# Native audio design and validation

This client must record a meeting hosted by another app, keep microphone and remote participants separate, and build using only Apple's Command Line Tools. That differs from a VoIP app that owns both ends of the call's audio graph.

## Capture and processing choices

Use **Core Audio process taps for system audio** and **AVAudioEngine for microphone capture**. Keep each source in its own file. A private, unmuted global stereo tap captures other apps' outgoing audio without selecting a display or requesting screen-sharing access. The tap feeds a private HAL aggregate device; microphone audio stays in a separate engine and file. These APIs support the client's macOS 26 deployment target without a virtual audio driver. Raising the minimum does not change the capture architecture. [Apple's Core Audio tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

The packaged app supplies `NSAudioCaptureUsageDescription`. Starting capture through the tap aggregate triggers macOS's system-audio permission request when needed; microphone access has its own request and purpose string. No screen video is captured, and system audio no longer requires an available display or ScreenCaptureKit content-sharing session. Permission decisions remain controlled by macOS; neither a successful API return nor silent samples prove access was granted. [System-audio purpose string](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription), [Apple's audio-only permission guidance](https://support.apple.com/en-au/guide/mac-help/mchl2844ecab/mac).

**Apple voice processing is an optional microphone mode.** It supplies echo cancellation, noise suppression, and automatic gain control. AVAudioEngine enables it while stopped and configures both input and output I/O. It requires device rendering, so offline/manual rendering is not an equivalent substitute. Keep the engine's output silent: replaying captured meeting audio or monitoring the microphone would create feedback or duplicate playback. [WWDC19 AVAudioEngine](https://developer.apple.com/videos/play/wwdc2019/510/).

Voice processing can reduce other apps' playback volume. Configure minimum ducking and leave advanced ducking off to minimize interference. **Settings → General → Automatically Process Microphone Audio** (on by default) selects the automatic policy: processing is enabled when the default output’s Core Audio stream terminal type identifies a speaker or low-frequency speaker, and when [echo detection](#echo-detection) finds system audio in the microphone. Headphones, line outputs, digital interfaces, and unknown or unreadable routes start unprocessed. With the setting off, recordings start unprocessed and nothing turns processing on. New Recording has no per-recording override; the live **Voice Processing** switch replaces it. The legacy saved `microphoneVoiceProcessing` preference is ignored. The route is read when the microphone engine is built, after microphone permission is granted and before capture creates aggregate devices. This detects the Mac’s default output, not an unrelated calling app’s independently selected output. Apple's documentation describes voice-processing capabilities, but it does not establish reliable cancellation of every unrelated app's speaker output across every device route. Do not label the result “echo-free.” Headphones avoid the speaker-to-microphone acoustic path; speakerphone quality requires real hardware testing. Voice Isolation is a system-controlled mic mode, not a second custom denoiser to stack blindly on top. [WWDC23 voice processing and ducking](https://developer.apple.com/videos/play/wwdc2023/10235/).

The Core Audio IOProc is a real-time callback. It copies Float32 input into a bounded, preallocated C ring and retains each buffer's input host timestamp; a separate consumer performs Swift processing and file writing. Callback arrival time includes scheduling delay and must not replace the input timestamp. Overflow or incompatible data fails explicitly rather than allowing unbounded memory growth or corrupting channel layout. The aggregate does not opt into waiting for a tapped application to start playing audio. Teardown stops IO before releasing callback memory, drains pending audio, and destroys the aggregate and tap. Taps do not provide noise suppression or acoustic echo cancellation. [Apple's real-time audio guidance](https://developer.apple.com/documentation/audiotoolbox/analyzing-audio-performance-with-instruments), [IOProc timing contract](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc).

### Output route detection

Read the default output's stream terminal types through Core Audio. Recognize both Core Audio's four-character speaker constants and the numeric speaker terminal types defined in [Apple's IOAudioFamily headers](https://github.com/apple-oss-distributions/IOAudioFamily/blob/main/IOAudioTypes.h). The built-in speaker on the validation Mac returned `0x0301`; checking only `kAudioStreamTerminalTypeSpeaker` missed it. Numeric desktop, room, communication, and low-frequency speaker endpoints also enable processing. Headphones and unknown routes remain off; device names, transport types, and jack presence alone do not identify an acoustic speaker path.

The route is read again on every microphone rebuild while the policy is automatic. This observes the system default route, not every other app's independent output selection.

### Device changes during recording

A route change does not end a recording. Capture follows the macOS default input and output, or the microphone selected in New Recording (see [Microphone selection](#microphone-selection)), not a device selected inside another app such as Teams or Zoom. The meeting, files, host-clock epoch, and elapsed timer stay the same; each source's engine or tap is replaced.

- **Triggers.** The microphone rebuilds after an engine configuration change, a new default input, a missing host timestamp, or 3 seconds without buffers. A microphone always delivers buffers, even silent ones, so a new engine that delivers nothing for 3 seconds is also rebuilt. System audio rebuilds after a tap format change, loss of its aggregate device, a ring failure, a new default output, or 3 seconds without buffers after it has delivered. Notifications are ignored when the default device ID has not changed, so capture's own aggregate and voice-processing changes do not trigger rebuilds. An engine configuration change is ignored when the engine is still running on the same device with the same hardware format; selecting a device can post one such change.
- **Retries.** `CaptureSourceRecovery` debounces notifications for 0.3 seconds, then retries with backoff from 0.25 seconds doubling to a 5-second cap for as long as recording continues. A new route notification resets the backoff. Each request has a generation number; a late attempt tears down what it built and installs nothing. A healthy source keeps recording while the other reconnects. A loop guard stops a rebuild from triggering the next one indefinitely: from the second rebuild in a row whose session never delivered audio, requests wait out the same doubling backoff (up to 5 seconds) instead of the debounce, and route changes stop resetting it. The first buffer from a new session clears the guard.
- **Voice processing.** In automatic mode, each microphone rebuild re-reads the output route; if the route rejects processing, capture continues unprocessed. A new default output rebuilds the microphone when processing is on, or when automatic mode now selects it. The route can also change without a new default device, for example when headphones are plugged into a built-in jack. While the microphone records, capture therefore also observes the current default output's data source, output stream list, and each stream's terminal type. It re-registers these listeners when the default output or its stream list changes and removes them at stop. When such a notification changes the speaker classification (see [Output route detection](#output-route-detection)) under the automatic policy, the microphone follows the same rule as for a new default output. Notifications that leave the classification unchanged are ignored. An explicit On or Off, including the echo latch, holds for the session.
- **Timeline.** Each track keeps its first format. The writer maps channels (duplicate to widen, average to narrow) and resamples later devices to that format. While a source reconnects, silence is written about once per second, staying 0.5 seconds behind the host clock, and gaps of 0.1 seconds or longer are saved in the track metadata. At stop, both tracks end at the same host time. The recording profile saves the voice-processing policy and every device, format, and processing change.
- **Terminal failures.** Writer errors end the recording. Revoked microphone access stops the microphone only; the recording ends only when every selected source has failed. System audio has no revocable permission reported by Core Audio, so it keeps retrying.
- **Stop & Save.** Stop cancels pending retries, removes listeners, and waits at most 3 seconds for native teardown. A Core Audio call that is still blocked after that is abandoned, not cancelled: its thread stays blocked until the call returns, then releases its session. Isolating capture in a helper process would bound this fully; that is deferred.
- **Status.** Until audio arrives, the recording header names the device a source is moving to: “Switching microphone to *Name*…” or “Switching system audio to *Name*…”. System audio follows the default output, so its name is the default output's. The microphone's name is the device its next rebuild uses: the selected microphone when it is connected and has not failed, otherwise the default input. This is the same name as “Using *Default*” in the fallback notices. The header shows “Reconnecting microphone…” or “Reconnecting system audio…” when no replacement device is available yet, or when the source is rebuilding on the device it already recorded from (for example after a watchdog rebuild or a Voice Processing change). When both sources are switching, the header shows “Switching audio devices…”, which fits on one line with long device names. Otherwise, when both are reconnecting, it shows “Reconnecting microphone and system audio…”. Each source meter's help text and accessibility value show “Switching to *Name*…” or “Reconnecting…”.

### Microphone selection

New Recording attaches a menu to the Microphone row: “System Default (*current default input*)”, then every input device by name. The menu lists devices with input streams and excludes hidden and aggregate devices, including capture's own tap aggregate and VoiceProcessingIO's aggregate. User-created aggregate devices are therefore not offered. Core Audio listeners for the device list and default input keep the menu current while the sheet is open. The choice is saved in settings as the device UID and name (`microphoneDevice`); older settings without it decode as System Default. A saved device that is not connected is listed as “*Name* (Unavailable)”, and capture records from the system default until it connects.

- **System Default** keeps the behavior above: capture follows the macOS default input.
- **A selected device** binds the engine's input element with `kAudioOutputUnitProperty_CurrentDevice` on element 1 before the format is read, again after voice processing is enabled (enabling it resets the input to the default device), and is read back after the engine starts. Each bind that changes the device leaves AVAudioEngine a pending configuration change. Capture calls `prepare()` and waits up to 0.5 seconds for that notification before it starts the engine. For voice processing, it waits after the graph is connected, because a prepared engine rejects the connection. The tap format takes its sample rate from the hardware side (`inputFormat(forBus: 0)`); the node's output format can still describe the previous device.
- **Fallback.** If the selected device cannot be bound, fails to start (with and without voice processing), reads back as another device, or starts without delivering audio for 3 seconds, the microphone falls back to the system default once and shows “*Name* unavailable · Using *Default*”. It stays on the default input until the selected device disconnects and reconnects; it does not retry a failing device in a loop.
- **Disconnection.** When the selected device is missing, the microphone records from the system default and the live view shows “*Name* disconnected · Using *Default*” (or “unavailable” if it was never connected during the recording). A device-list listener rebuilds the microphone when the selected device returns. Default-input changes rebuild the microphone only while the selected device is absent. Each switch is saved in `routeChanges` with the device name and a reason (`selectedMicrophoneUnavailable`, `selectedMicrophoneReturned`).

Measured on this Mac (macOS 26.6.2, a virtual input device as the selected non-default microphone, built-in speakers as output):

| Sequence | Result |
| --- | --- |
| Unprocessed, `AUAudioUnit.setDeviceID` or element-1 property | Selected device runs; built-in microphone idle. |
| `setDeviceID`, then enable voice processing | Input reset to the built-in default microphone. |
| Enable voice processing, then `setDeviceID` | Output element moved to the selected device; the built-in microphone also ran. |
| Enable voice processing, then element-1 property | Input on the selected device, output on the default speakers, buffers delivered after about 1.2 seconds. |
| Element-1 property, then start at once (from a background queue, as capture does) | The engine stops itself on the pending configuration change: no buffers. On the main thread it kept running but posted `AVAudioEngineConfigurationChange` about 0.1 seconds after start. |
| Element-1 property, `prepare()`, wait for the change, then tap and start | The change posts after about 0.1 seconds; afterwards the engine runs and delivers, with no further notification. Same with voice processing when the wait follows the graph connection. |
| Tap format rate different from the hardware rate | AVAudioEngine logs “Format mismatch” and “Failed to create tap, config change pending!”; no buffers. |

`AUAudioUnit.setDeviceID` is not deprecated, but on VoiceProcessingIO it selects the output device, so capture uses the element-1 property for both modes. These probes confirm routing only. Echo cancellation quality with a non-default input, and behavior with USB, Bluetooth, or Continuity microphones, were not measured. If processing cannot be enabled on the selected device, capture records it unprocessed and says so (see below).

### Live Voice Processing switch

The recording view shows a small **Voice Processing** switch under the Microphone meter when the microphone is recorded. It shows the running engine's state, so automatic changes (route, echo detection, fallback) move it too. Changing it sets an explicit On or Off policy for the rest of the recording and rebuilds only the microphone through its recovery controller; the brief gap is padded and saved like any reconnect, and the change is saved with reason `voiceProcessingSwitched`. The switch is disabled while that rebuild is pending or the microphone is reconnecting, instead of queueing changes. Stop & Save stays available.

When voice processing cannot be enabled (any policy, any device), capture continues unprocessed, the switch shows Off, and the view shows “Voice Processing is unavailable for *Device*”. The route change is saved with reason `voiceProcessingUnavailable`. Earlier versions kept retrying an explicit On; recording the microphone unprocessed, and saying so, is preferred to a silent track. The recording profile's `voiceProcessingPolicy` is the policy at start; later changes are in `routeChanges`.

### Echo detection

Echo here means system audio played through speakers reaching the microphone. `EchoDetector` compares loudness envelopes, not waveforms:

- Each captured buffer's mean square (already computed for the meters) fills the 20 ms bins it covers, keyed by host time, in fixed-size rings. No audio is copied, and adding a value never allocates.
- Once per second, on the capture queue, it computes the normalized cross-correlation of the last 6 seconds of microphone envelope (in dB, floored at -80 dB) against the system envelope at lags 0–400 ms, with the microphone lagging. That is about 300 bins × 21 lags.
- It evaluates only when both windows are at least 80% covered and the system envelope is informative: a standard deviation of at least 3 dB and a 90th percentile of at least -50 dB. Silence and steady noise do not count.
- A correlation of 0.75 or more in 3 consecutive evaluations reports echo; 5 consecutive active evaluations below it clear the report. Synthetic tests: a delayed, attenuated copy correlates at 0.98–0.99; independent speech-like envelopes stayed below 0.62 and were never reported; simultaneous near-end speech at the echo's level lowers the correlation to about 0.4–0.65, so echo is reported once the near end is quiet; the delay estimate is within 40 ms. The threshold sits well above chance alignment because a false report turns on processing for the rest of the session, while a missed report leaves the speaker-route default in place.

Detection runs only when both the microphone and system audio are recorded and the microphone is unprocessed. With the automatic policy, a report switches processing on, latched for the rest of the recording (it is never switched off automatically), shows “Echo detected · Voice Processing turned on” for 10 seconds, and saves reason `echoDetected`. With an explicit or setting-selected Off, capture changes nothing and shows “Echo detected” beside the switch. With processing on, nothing changes. Each microphone rebuild restarts detection.

Limitations: envelope correlation needs system audio with speech-like level changes; continuous double-talk, heavy room reverberation, or a very quiet leak can keep it below the threshold, and steady music may never qualify. It cannot distinguish leaked playback from the same content reaching the microphone another way. Thresholds were tuned on synthetic envelopes only.

## Live consumer backpressure

Capture owns source recovery. File writers, the recording clock, and `LiveAudioSink` subscriptions survive source rebuilds. Transcription and speaker labeling consume independent queues, each limited to two seconds of PCM; a stalled subscriber does not block another subscriber. Invalid timestamps are rejected before updating source positions.

SpeechAnalyzer pulls converted input directly from its source queue. There is no second packet-count buffer: small system-audio callbacks have the same duration budget as microphone callbacks. A timestamp gap resets conversion history and reports missing coverage without waiting for the UI. Stop closes the queue and waits for the analyzer to consume accepted input and finalize results, following Apple's [end-of-input contract](https://developer.apple.com/documentation/speech/speechanalyzer).

Loss metadata is bounded separately from PCM. When exact disjoint ranges exceed the bound, the overflow retains a conservative interval explicitly marked as uncertain. A bounded gap reporter delivers updates asynchronously. Draft checkpoints keep one background save and the latest pending snapshot; finalization waits for persistence. Slow UI updates and JSON encoding therefore do not directly block recognition input. This does not recover audio lost before capture or guarantee real-time recognition under sustained overload.

## Recording diagnostics

Capture writes structured entries to the unified log under the subsystem `com.gdaymeetings.macos` (`com.gdaymeetings.macos.preview` for UI Preview), in categories `capture` (source setup, device binding and read-back, formats, voice-processing decisions, triggers, watchdog firings, fallbacks, and frames at stop) and `recovery` (rebuild scheduling, attempts, errors, backoff, and the loop guard). Entries describe decisions and state changes, never individual buffers or audio content. Device names are public in the log; other values are technical.

- Live: `log stream --level info --predicate 'subsystem == "com.gdaymeetings.macos"'`
- **Help → Follow Logs** opens Console. Select your Mac, click **Start**, and filter by subsystem `com.gdaymeetings.macos` (or `com.gdaymeetings.macos.preview` for UI Preview). Choose **Action → Include Info Messages** for informational entries. The app does not automatically configure Console's filter or streaming state.
- Earlier runs: `log show --last 30m --info --predicate 'subsystem == "com.gdaymeetings.macos" OR (process == "GdayMeetings" AND subsystem == "com.apple.avfaudio")'`
- In the app: **Help → Export Logs** (also in **Settings → Data Privacy**) saves the last hour of this app run's entries, including the `network` category, plus AVAudioEngine's, to `~/Library/Logs/Gday Meetings/` and shows the file in Finder. `OSLogStore` limited to the current process needs no entitlement, so earlier app runs need `log show`.

AVAudioEngine's own entries (`com.apple.avfaudio`) record engine start, stop, configuration changes, and format mismatches; they identified the device-selection loop described in the September 26, 2026 worklog. Core Audio's HAL entries are too verbose to export by default.

## Track and file invariants

- Keep permission/setup delays outside the recording timeline; use a shared capture epoch once sources are ready.
- Use capture timestamps to retain gaps and align sources. Never assume callback arrival times or buffer counts alone establish synchronization.
- Fix each track's format at its first device, convert later devices to it, and preserve duration; retain capture format and route-change metadata. Opus storage uses a 48 kHz timeline with native sample-rate conversion. Stereo channels are not two independent speakers; source tracks and diarized identities are different concepts.
- Keep microphone monitoring off and exclude this app's playback from system capture.
- Keep file I/O away from hardware render callbacks. Own any buffer memory that outlives a callback, bound queued work, and surface write/format/route failures.
- Drain pending writes before closing files. A partial recording with an explicit failure is preferable to silently claiming a complete recording.
- Stream Opus (the default) to each track’s file during capture. A bounded worker owns copied PCM, encoding, and disk writes; Stop drains accepted audio and writes the final Ogg page. WAV records directly; M4A retains recoverable PCM spools until encoded tracks and metadata are saved successfully. Never replace saved recordings during later playback/export/service conversion.

## Recording formats

New Opus recordings target **32 kbps per track**, for mono and stereo, with a 48 kHz encoding timeline. The bundled libopus encoder uses its speech application, voice signal hint, VBR, complexity 5, and discontinuous transmission (DTX), matching the Rust client’s defaults. DTX reduces packet size during silence; every packet remains in the Ogg file so timestamps and silent intervals are preserved. Bitrate targets are not exact file-size guarantees. Capture retains each source’s initial format and uses continuous sample-rate conversion when needed. Existing recordings are not re-encoded. [Opus encoder controls](https://www.opus-codec.org/docs/opus_api-1.6/group__opus__encoderctls.html).

The C encoder bridge extends the already bundled, statically linked libopus library. It introduces no C++ interoperability or new runtime dependency. Swift writes Ogg headers, pre-skip, checksums, and final granule trimming according to [RFC 7845](https://www.rfc-editor.org/rfc/rfc7845) and [Ogg framing](https://www.xiph.org/ogg/doc/framing.html). AAC continues to use Apple’s native encoder. Interactive Ogg Opus playback uses libopusfile to read and seek incrementally without a temporary decoded file. Server transcription receives the original Opus. Native MP3 encoding is unavailable on the tested Mac; MP3 input remains supported.

Opus capture does not create a whole-meeting WAV copy. Encoder/write failures are reported and the partial Opus file is retained; it cannot recover source PCM that was never encoded. Each completed Ogg page is written during capture, and normal Stop writes EOS and synchronizes the file. An abrupt process or disk failure may leave the trailing page incomplete or without EOS; this change does not add crash-repair tooling. Tests cover DTX duration, final samples, sample-rate conversion, live writes, and bounded capture queues. See the [streaming recording worklog](../../../docs/worklogs/2026-10-01-streaming-opus.md).

## Transcription and transcoding

Use Apple's AVFoundation codecs, not an external `ffmpeg` executable. Preserve separate inputs when submitting a server task; report the prepared file's actual channels. Large PCM or unsupported containers are converted to a separate AAC/M4A file. A successful export must have completed successfully, contain readable audio, and satisfy the receiving service's size constraints.

Transcription runs on the Gday Meetings website or on RunPod, which reads each track from a Filedrop upload link. The OpenAI-compatible provider handles summaries only. Server-side workers retain responsibility for resampling, recognition, and diarization. Neither stereo layout nor acoustic echo cancellation substitutes for speaker diarization.

Server upload checkpoints preserve the exact uploaded inputs and attempt key, so retries do not silently create a new transcription job. Immutable archive checkpoints retain their converted bytes and hashes, allowing readback verification without deleting local originals.

## Validation

Automated checks use synthetic audio and temporary libraries. They can establish correct file formats, sample values, channels, timeline arithmetic, persistence, and HTTP contracts. They cannot establish acoustic echo cancellation quality, microphone permissions, Bluetooth behavior, or real speakerphone performance.

Before claiming a route is validated, exercise the following on physical hardware:

| Scenario | Check |
| --- | --- |
| Built-in mic + speakers, processing off/on | Remote speech leakage into mic, near-end intelligibility, simultaneous speech, startup convergence, and playback ducking. |
| Wired/USB headset | Clean separate tracks, no feedback, sample-rate and channel correctness. |
| Bluetooth headset | Input/output profile changes, bandwidth changes, recording continuity, and explicit handling of disconnection. |
| Headphones plugged into or removed from a built-in jack during capture (same output device) | With the automatic policy, the log shows the speaker classification change; the microphone rebuilds only when processing is on or now selected; unrelated notifications are ignored. |
| Output/input route changes during capture | Recording continues on the new default devices without user action; gaps are silent and recorded; tracks stay aligned; automatic voice processing follows the output; no duplicate playback. |
| Selected USB or Bluetooth microphone | Recording stays on it when the default input changes; disconnect switches to the default with a visible notice; reconnect switches back; voice processing on the selected device reduces echo, or the unavailable notice appears. |
| Built-in microphone selected while Bluetooth headphones are the default input and output | The microphone meter shows audio within about a second, with no repeated “Reconnecting microphone…”; the recording profile has one microphone route; system audio records. |
| Built-in speakers with processing off | Echo detection reports leakage within about 10 seconds of remote speech; automatic policy turns processing on; headphones never trigger it. |
| Voice Processing switch during recording | Short saved gap only on the microphone track; system audio continues; Stop & Save stays available. |
| Silent system audio for over 3 seconds | The tap keeps delivering buffers, so the watchdog does not rebuild system audio repeatedly. |
| Quiet system audio or muted microphone | Distinguish silence from missing callbacks; do not infer permission denial from silence alone. |
| Long meeting | Bounded memory, stable track alignment, valid final containers, conversion size limits, and resumable server processing. |
| App quit, device loss, sleep, disk failure | Finalization or an actionable failure; previously saved material remains readable. |

Do not use synthetic test success as evidence that all of these hardware scenarios have passed.

## Streaming playback and waveform cache

`StreamingPlayback` owns file readers and the engine on a serial worker queue. Opus uses libopusfile's pre-skip, gain, end trimming, and seek preroll; native formats use AVAudioFile and continuous AVAudioConverter resampling. A fixed 16,384-frame stereo ring per track (about 341 ms at 48 kHz) feeds one AVAudioSourceNode and AVAudioUnitTimePitch. The render callback performs only bounded mixing and atomic cursor access: no file reads, decoding, locks, or allocations. Tracks share one consumer cursor; starvation emits silence without advancing media time. Playback progress publishes at 60 Hz from consumed source frames; output/time-pitch buffering can put the cursor slightly ahead of audible output. Seeking stops and resets the graph before replacing buffered samples. Device changes invalidate the prepared playback engine. Active playback pauses and shows “Audio output changed. Press Play to resume with the current device.” A paused item stays quiet and rebuilds for the current device on the next Play. Playback route changes do not cancel summary or transcription tasks.

Source and working PCM memory are bounded independently of meeting duration. libopusfile seeks using Ogg page granule positions without building a full PCM file or scanning every packet. Supported Opus input is single-link mono/stereo; chained or multichannel files fail visibly. The transport supports up to 32 tracks. See [pinned offline dependencies](../ThirdParty/README.md) for build and license management.

Waveform work runs independently of playback. Up to 1,200 evenly spaced buckets sample at most 1,024 frames each; channel peak magnitudes preserve opposite-phase stereo. This is an approximate overview and can miss brief transients between windows. Opus seeks include codec preroll, so its work exceeds the sampled PCM count but remains bounded by the number of buckets. Versioned JSON envelopes in the app cache validate source path, size, creation time, and modification time. Cached envelopes can display before audio preparation finishes. Service/transcription conversion still uses temporary compatible audio when necessary; that path is separate from playback.
