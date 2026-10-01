---
title: Local speaker providers and model controls
date: 2026-10-01
status: ready-for-user-testing
scope: swift-speaker-providers
---

# Local speaker providers and model controls

## Problem

Speaker labels were coupled to server transcription. The app had no independent local live-label provider, saved-audio label action, or shared model installation controls.

## Implemented solution

Nemotron provides **Live Speaker Labels**. Community-1 provides **Speaker Labels** and **Speaker Recognition**. These capabilities and their Defaults selections are independent of transcription. Existing settings decode with live labeling and recognition off. Local providers require no endpoint, API key, or upload provider.

The user's annotated Defaults screenshot places **Live Speaker Recognition** in **Live Transcription** and **Speaker Recognition** in **Transcription**. These switches persist independently; the former controls new live sessions and the latter controls matching after transcription. The separate Speaker Recognition section retains the shared provider picker. Older settings decode the new live switch as off.

An offscreen capture of the production Defaults component was inspected with live recognition on and saved recognition off. Both controls appear in the requested sections; the fixture supplies synthetic settings and dependency state. Decode tests cover both opposite combinations and an older file with neither key.

Final UI review added the Nemotron analysis dependency beneath live recognition, while keeping the recognition and label-display switches independent. Switching presets resets model-specific view errors. Deleted people render as unassigned fallback badges instead of retaining an assigned appearance; a regression covers this case.

Service Providers retains its existing provider list and grouped form. Local panels show capability switches, preset selection, model size and buffering delay, download progress, cancellation, retry, verification, preparation, ready state, and removal when assets are unused. **Open Model Folder** and **Manual Installation** describe the exact top-level files required by the selected immutable revision. Refresh discovers copied files; verification and preparation precede readiness. Download controls observe the shared manager so work survives closing Settings. The Nemotron picker reads all seven supported presets from the common catalog; it makes no device-placement claim.

The live transcript has independent speaker-label and recognition switches and status messages. Assigning a detected speaker can update linked passages; **Apply to This Speaker** can be turned off for a correction to one passage. Placeholder assignments remain passage-specific. Editor and picker callbacks retain the displayed phrase and meeting identity, preventing later recognition changes from expanding a manual edit's original range.

The saved transcript offers **Label Speakers** for the selected ready Community-1 provider and **Cancel Speaker Labels** while it runs. This is separate from transcription. The runtime and reversible result application are implemented in the corresponding core services.

## Reasoning

Before editing Settings, an isolated full-app test captured and inspected the existing Service Providers screen. The design preserves its 205-point provider column and grouped form rather than introducing a second settings layout. Model state is shown beside the selected preset; Defaults exposes missing readiness without preventing configuration. Manual installation uses the same verification path as downloads.

The narrow native transcript screenshot also revealed a pre-existing wrapped-text clipping problem. Row height now measures the actual table-column width rather than the wider document bounds, accounting for native style insets. The new narrow screenshot shows every line.

## Validation

The baseline Settings capture used a temporary library and an offscreen window; it did not open the user's app or download a model. The baseline capture test passed. The narrow transcript fix was re-rendered and inspected. Updated local-provider component captures were inspected for missing, downloading, failed, unverified, and ready states, including light and dark appearances. Controls fit the production panel width, and download progress shows transferred and total bytes. These use the production view with synthetic manager state; they validate presentation, not download, inference, or full native event handling.

Provider regressions cover independent local capabilities, credential-free configuration, all seven preset round-trips, rejection of unsupported models, independent settings round-trips, safe defaults for older files, and preventing saved labeling with missing, disabled, incorrect, or capability-disabled providers. The native table also pauses live following on mouse or keyboard selection and context-menu access without treating programmatic selection as user input; a live timestamp does not advertise unavailable playback. Scoped formatting, strict lint, and diff checks pass. Integrated tests, model lifecycle checks, and release validation are complete; results and limits are recorded below.

## Technical debt

Provider settings retain optional defaults for existing libraries. Voice-profile storage retains the compatibility bridge described below. Readiness and model leases belong to the shared manager; the UI does not infer readiness from file presence. Per-device placement, combined-runtime resource use, recognition quality, and long-running capture remain validation obligations, not properties established by provider registration or screenshots.

## Shared model and voice profile implementation

The app pins FluidAudio to the benchmarked revision with optional traits disabled and retains Swift 5 language mode. Seven Nemotron presets use the same upstream configuration API. Every asset has an immutable repository revision, byte count, and content hash. Downloads share verified files across installations; cancellation preserves completed files, while an interrupted file is downloaded again. A saved preparation receipt triggers fresh verification and Core ML preparation after a restart. A folder copied manually starts unverified. Leases prevent removing models in use, and removing one installation preserves files linked by another. FBank uses CPU execution as required by the tested extraction path; other models use Core ML's automatic compute selection.

Acquiring a previously prepared model performs startup verification without requiring Settings to be opened. Verifying a manually copied Community-1 installation also makes its identical embedding files available through shared local storage, without downloading them again.

Each lease opens separate Core ML instances. This follows [Apple's requirement to serialize calls to an individual model](https://developer.apple.com/documentation/coreml/mlmodel) and prevents independent jobs from sharing prediction state. The stored model assets remain shared. Saved-audio extraction accepts only finite, bounded speech spans, and source mapping recognizes exact recording filenames rather than substrings in arbitrary imported names.

Voice samples now carry the model revision, preprocessing compatibility version, dimension, and normalization. Matching checks the complete type before comparing normalized vectors. One person can retain samples from several types. Older vectors remain readable as unknown types and cannot produce new automatic matches. Exports remove typed vectors alongside older voice data.

The production manager passed an isolated synthetic lifecycle probe covering copied folders, hash failure, cancellation, retry, restart verification, in-use removal, and shared-file removal. A separate real-model probe copied existing Community-1 and Nemotron low assets, verified their pinned files, prepared their Core ML models, and acquired leases. It also downloaded and verified the 102,096,652-byte split fast32 preset and acquired its prepared model. These probes used isolated model folders. They establish installation and loading behavior, not recognition accuracy or device placement.

The retained voice-profile compatibility bridge preserves old raw fields so existing libraries remain readable. Re-enrollment with a declared model type is required before those samples can support recognition; a future schema migration can remove the redundant raw representation after older-client compatibility ends. Initial recognition score and margin thresholds are conservative policy values, not calibrated identity probabilities; calibration needs separately reviewed enrollment and query recordings.

## Live pipeline and draft integration

Live audio now has independent bounded subscriptions for Apple transcription and Nemotron. Each source has its own resampler, diarizer state, recording clock, and identity generation. A missing model or failed analysis leaves capture running. Becoming ready during a recording starts a new generation and records the earlier unlabeled range. Overflow and discontinuities reset model state and retain an explicit coverage gap. Finalization detaches capture, drains the bounded queues, flushes model output, and preserves completed results within a deadline.

Nemotron activity joins recognized word times. Missing word timing keeps the phrase boundary; overlap remains unassigned instead of selecting an arbitrary person. Source defaults such as `mic_01` and `sys_01` are anonymous display labels. Model identities are unique to a source and generation, and retired generations cannot overwrite a newer timeline. The display activity policy is versioned as `hysteresis-55-45-on50ms-off100ms-v1`: five consecutive 10 ms frames at or above 0.55 activate a slot, and ten below 0.45 deactivate it. This suppresses brief changes while retaining overlap. It differs from the benchmark's raw 0.5 threshold; its accuracy has not been re-evaluated against the human annotations.

Speaker recognition samples clear, nonoverlapping speech after at least three seconds and spaces attempts by at least five seconds per identity. It retains at most 46 seconds of 16 kHz audio per source, trimming to 45 seconds in batches. Extraction work is bounded to one pending task. Three consecutive compatible profile matches are required before an automatic name is shown. The latest typed vector is checkpointed with its identity and survives adoption into the saved meeting. Automatic matches do not enroll a voice. Explicit assignments can enroll clean vectors, preserve samples from other model types, and remove the prior attribution's contribution when cleared or reassigned.

Manual text and person changes are stored separately from recognition results and anchored to their original session, source, and time range. Captured editor anchors remain applicable after a partial result is replaced, split, or merged. A person-only assignment cannot promote unfinished recognition to final text. Explicitly edited pending text is retained as user-authored text. If revised recognition lacks enough word timing to divide an edited range safely, the surrounding recognized text is retained and the unresolved timing is marked; some duplicate text can remain until reviewed.

Regression coverage includes independent queue overflow and unsubscribe behavior, generation retirement after checkpoint decoding, activity hysteresis and overlap, typed-vector persistence without automatic enrollment, anchored edits across recognition changes, legacy draft decoding, and manual enrollment cleanup across people and model types. Opt-in paced adapter tests exercise the production runtime with synthetic audio and installed low or split assets. Integrated test and release results are recorded below after execution.

The retained timing fallback avoids deleting recognized words but can duplicate an untimed phrase around a manual edit. Better recognition timing or a range-review control can resolve that ambiguity. The activity and recognition thresholds remain explicit, uncalibrated policies; calibration on separately reviewed recordings is required before making quality claims. Sustained multi-source recording, end-to-end speaker-name accuracy, and actual Core ML device placement remain separate validation obligations.

Live recognition starts the required Nemotron analysis even when the speaker-label display switch is off. Disabling the display does not interrupt recognition; turning both features off detaches the worker. If the dependency is unavailable, recognition reports that it is waiting for Nemotron rather than claiming to be listening for clear speech. A controller regression covers the missing-provider path and independent switches. Local-processing journal receipts now cover live speaker analysis, live embedding recognition, and saved Community-1 processing, with start and end times and no remote destination.

## Saved-audio labeling and extraction

Community-1 runs from a verified lease on each retained audio track. The job writes its complete speaker intervals locally and creates a transcript history revision. Applying labels preserves text, segment identities, and existing person assignments. Coarse phrases require a clear majority speaker; overlap and ambiguous track mapping keep their existing labels. Missing audio, cancellation, changed transcript sources, and empty speech results do not replace the current transcript.

The shared embedding extractor uses the pinned FBank and embedding models on finite, bounded 2–10 second selections with an explicit mask. A synthetic five-second extraction produced a finite 256-dimensional normalized vector. Saved labeling extracts the longest suitable nonoverlapping span; live recognition supplies its bounded clean-speech selections. Both use the same declared preprocessing type.

Saved labeling cancellation takes effect at safe inference boundaries; it does not interrupt a synchronous Core ML prediction. This job is not resumed after app termination. Transcript history preserves the previous result, but durable job recovery remains a follow-up if long recordings make restart recovery necessary.

## Integration validation progress

The first complete release build passed in an isolated checkout. The first full parallel test run reached 567 tests and reported 15 issues: deadline failures in task/summary/file-monitor tests and the live finalization deadline test. Investigation found contention consistent with delayed main-actor scheduling; a sequential rerun is required before concluding these are only harness timing failures. No production deadline was increased to hide the failures.

The standalone Command Line Tools linker reports missing developer-library search paths. These are toolchain-generated paths; they do not prevent linking. The initial Swift capture warnings were corrected. Final source-matched release and test results will be recorded below.

The source-matched sequential suite passed **569 tests in 106 suites** in 65.396 seconds, including the finalization test and every previously failing deadline test. The initial parallel failures therefore remain a test-concurrency limitation. A single-preset standalone Nemotron low acquisition passed in 63.857 seconds. Sampling the earlier multi-model smoke setup showed simultaneous Core ML specialization waiting on the ANE compiler; the Community smoke setup now acquires only its requested model.

The targeted production-adapter run passed five tests: Community-1 processed synthetic audio and returned valid typed embeddings; Nemotron low consumed paced microphone and system streams, emitted speech intervals, preserved separate identity namespaces and clocks, finalized both sources, and released its lease. Community-1's end-to-end test took 1.607 seconds; low's test took 88.659 seconds including model preparation and paced playback. These times describe this smoke test, not comparative inference latency or resource benchmarks.


## Final validation

- The final isolated `make build-macos` release build passed. Bundle property-list validation and signing passed. SHA-256 checks confirm all 277 app source/configuration files match the tested snapshot.
- Sequential regression validation passed 569 tests in 106 suites. The parallel run's deadline failures remain a test-concurrency limitation; the production timeouts were not weakened.
- Nemotron low and split fast32 both passed the same paced two-source adapter test. The split run took 133.060 seconds including preparation and paced playback, with independent source identities, correct final boundaries, no reported gaps/errors, and released model leases. Other presets have catalog/configuration coverage but were not all exercised through live audio in this validation.
- Community-1 processing and typed voice extraction passed on synthetic speech. Model lifecycle probes covered manual installation, hashes, cancellation, retry, restart, and leased/shared-file removal.
- Swift formatting, strict lint, and diff whitespace checks passed. Updated production-component screenshots were inspected. Native mouse/keyboard interaction and live hardware capture still require user testing; computer-use automation was unavailable.
- The release retains Command Line Tools linker warnings for missing developer-library search paths. No Swift capture or deprecation warnings appeared in the final build. These results describe local validation; the remote macOS matrix is checked after publishing the commits.

The test bundle is in the ignored isolated checkout at `tmp/live-transcript-unification/checkout/apps/client-macos-swift/.build/macos/Gday Meetings.app`. The running app was not replaced or restarted. Long-session combined resource use, device placement, and speaker-name accuracy remain unmeasured; the earlier diarization benchmark does not establish these properties.

## Download progress correction

An 8 MiB throttled loopback transfer reproduced the reported progress freeze: the async `URLSession.download(for:delegate:)` path completed with zero byte-progress callbacks. The model manager now uses a session-owned download delegate and an explicit download task, preserving the temporary file before the delegate returns. Cancellation resumes the awaiting task with cancellation and removes partial output; a later retry starts normally. UI updates are monotonic and scoped to the current setup attempt so delayed callbacks cannot affect a retry.

The same standalone fixture produced 128 progress callbacks after the fix, including 17 callbacks and 1,114,112 received bytes at a check before completion. Cancellation left no temporary output, and retry completed successfully. A repository regression uses the existing throttled HTTP fixture to check partial-byte updates, ordering, cancellation cleanup, and retry. The standalone probe and repository regression passed. The final sequential suite passed 571 tests in 106 suites after this correction. The transfer uses [Foundation's download delegate lifecycle](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask), including moving the temporary download before its callback returns.

This correction adds no storage or protocol compatibility bridge. Retry still reuses previously verified model files and restarts an interrupted file; byte-range resume remains unimplemented.

The follow-up isolated release build passed in 192.54 seconds, with successful bundle validation/signing and unchanged toolchain search-path warnings. Formatting, lint, and diff checks passed. The release sources match the final 571-test snapshot.
