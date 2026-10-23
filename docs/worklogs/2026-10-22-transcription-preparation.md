---
title: Automatic speech model preparation and live status
date: 2026-10-22
status: complete
scope: swift-app-transcription
---

## Problem

Apple transcription already downloaded missing supported models, but provider readiness directed users to download manually. The live transcript empty state ignored preparation messages and showed “No Live Text Yet” during loading.

## User Intention

Download a language model automatically when first transcribing, keep recording available during preparation, show a provider-supplied Loading state and description, retain manual downloads, and remove missing-model warnings from Capability Providers. The runtime state should be reusable by other providers. Replay speech captured during preparation so live text catches up when the model is ready, using the same recognition session.

Preserve that preparation replay while bounding later live backlog, report overflow through existing gap handling, and remove abandoned temporary audio safely across multiple running app identities.

## Implemented solution

Supported and downloading Apple assets count as an available capability. Unsupported languages, hardware, disabled capabilities, and unsupported assets still report errors. Installed-model inventory remains separate from capability availability.

ProviderActivity carries typed loading, active, failure, and idle states. Apple preparation supplies checking, downloading, and loading descriptions. Recorded transcription forwards those descriptions into its existing task status. The live controller publishes preparation state and ignores stale callbacks after language changes, retries, disabling, and Stop. Preparation failures offer Retry both in the empty view and above existing transcript rows.

The user screenshots establish the previous layout. The intended empty-state design uses a progress indicator, “Preparing Live Transcription,” and one provider-supplied description. Once prepared, an empty transcript says “Listening.” Existing rows remain visible with a compact preparation indicator during a language restart.

Preparation queues are attached before capture begins and passed into the Apple analyzer when ready. The queue uses bounded memory with temporary disk overflow; one analyzer per source consumes earlier and live audio in order. Cancellation, disabling, language changes, and Stop dispose of the previous queue. Stop retains the existing five-second finalization deadline; recordings saved before preparation completes remain available for full transcription.

Once analyzers start, accepted preparation audio remains available to drain and subsequent capture uses the normal two-second queue budget. Audio arriving while that budget is full records an exact transcription gap. Sustained slow recognition therefore stops adding disk backlog after preparation; recording continues independently. The subsystem sweeps abandoned, leased temporary directories once per process on its background worker. A nonblocking exclusive lease prevents cleanup from deleting another running app's backlog, and a one-minute grace period protects directory creation.

The provider settings panel now reads both readiness results from its own validation cache, including when a capability is not selected in General.

## Reasoning

Keep readiness as the ability to start an operation; show runtime preparation where the operation is happening. Apple consolidates automatic and manual asset requests, so no application-level download scheduler is needed. Recording remains independent of recognition startup.

Reference: [Apple asset installation](https://developer.apple.com/documentation/speech/assetinstallationrequest/downloadandinstall%28%29).

## Technical debt

Older builds created temporary audio directories without ownership leases. Automatic cleanup retains those directories because an older running app may still use them; this compatibility limit requires manual cleanup after those apps quit. Newly created leased directories are removed after consumption or cancellation, or swept when a later process first creates a live audio backlog after a crash. The one-minute cleanup grace period can defer removal until another launch. Remove the legacy-directory exception after older builds are retired and ownership can be established safely.

Preparation audio can grow on disk while model installation is pending, subject to available disk space; disk failure reports gaps. Once analysis starts, new live capture uses a two-second budget while existing preparation audio drains. The five-second Stop deadline can leave that earlier audio untranscribed; the finalized recording remains available for full transcription. This bounds capture work and preserves timely saves without a second concurrent recording reader.

## Notes

Final focused release tests passed: 146 tests across 21 suites, including delayed replay beyond the normal memory budget, exact PCM/timestamps, multi-chunk cleanup, disk failure, producer limits, cancellation, Stop before preparation completes, retries, stale callbacks, retained text, readiness, and existing transport/transcript regressions. Generated English and Mandarin passed with Favor Accuracy on and off: both sources recovered pre-start speech, continued into live speech, and reported no gaps. Strict scoped formatting and diff checks passed.

Rendered isolated previews matched the loading and failure designs. Checked loading spinner and provider text, Stop & Save during preparation, failure Retry returning to Listening, both This Mac capabilities showing Ready, manual Download controls, and no Apple missing-model warning in Capability Providers. Screenshots were inspected through the native UI tool. Preview launches were slow; user recordings and the main library were preserved.

Isolated `make build-macos` passed, including platform verification and ad-hoc signing. The build is `tmp/accuracy-validation/apps/client-macos-swift/.build/macos/Gday Meetings.app` (base commit `f3d0cbe` plus this working tree); it was not installed over the running app. Existing Command Line Tools linker warnings reference missing `Developer/Library/Frameworks` and `Developer/usr/lib` search paths; no new deprecation warning was observed. Actual first-time network downloads and network failures were simulated through injected preparation/readiness states; real recognition used installed Apple models. The five-second finalization deadline can leave a large backlog incomplete at Stop; saved audio remains available for full transcription.

Independent Sol review found a missing Retry action when rows already existed, plus cancellation checks needed before initiating installation. Both were fixed, a row-preservation regression was added, and follow-up review found no blocking issues. A canceled preparation returning success also has a regression test, alongside delayed status and throwing cancellation paths. Catch-up review found that capture starts before the controller; queues now attach before capture starts, and a setup-failure defer disposes them unless ownership transfers to the controller. Follow-up review found no blocking issue. The existing five-second Stop deadline was retained to avoid delaying recording saves; a larger unfinished backlog leaves the live draft incomplete.

Opus review identified continuous disk buffering after readiness and crash leftovers. The readiness transition now preserves earlier preparation packets while enforcing the live budget for later packets. Lease-backed cleanup protects active backlogs across app identities. All 15 focused tests across three suites passed, covering transition ordering, overflow gaps, resumed live admission, abandoned-directory removal, active-lease protection, fresh-directory grace, preservation of unleased or unrelated directories, and existing preparation lifecycle and adapter behavior. Strict scoped formatting and whitespace checks passed; only the existing toolchain linker search-path warnings were observed. The lease check uses separate open handles in one process; a deliberate crash and two-app runtime trial were not performed.
