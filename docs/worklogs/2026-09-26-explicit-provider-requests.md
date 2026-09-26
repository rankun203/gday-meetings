---
title: Explicit provider requests and model list
date: 2026-09-26
status: implemented; not yet checked on screen in UI Preview
scope: swift-app-and-protocols
---

## Problem

The Data Privacy audit found two automatic request paths in the Swift client. Both were confirmed in code:

- **Language discovery on picker display.** `MeetingLanguagePicker` ran `.task(id:)` → `loadProviderLanguages` whenever a picker appeared (New Recording, meeting detail, Settings → Recording). For RunPod this posts `runsync` with the `capabilities` operation, which starts a serverless job and can incur charges. The in-memory cache expired after five minutes, so the job could repeat after every relaunch or once the cache expired.
- **Connection checks on panel open, including disabled providers.** `ServiceProviderPanel` ran `.task { startCheck() }` and rechecked whenever the Settings window became key. `startCheck` did not consider `isEnabled`.

A follow-up request asked for an OpenAI-compatible **Model** menu filled from `GET {endpoint}/models`. It also refined the rule: free, credential-only metadata may run automatically for enabled providers, billable work needs an explicit action, and disabled providers are never contacted automatically, except to list models while their panel is being edited.

## Implemented solution

Code is under `apps/client-macos-swift/Sources/GdayMeetings/`.

- **Saved metadata.** New `Services/ProviderMetadataCache.swift` is a generic per-provider cache: provider ID, a SHA-256 fingerprint of non-secret configuration, the value, and `fetchedAt`. It is stored as JSON in the library folder (`provider-languages.json` and `provider-models.json`) and entries for removed providers are pruned on write. `MeetingStore` gains two lazy properties and loses `providerLanguageFetchedAt`.
- **Languages.** `ProviderLanguageIdentity` now hashes kind, endpoint, and model; the API key, enablement, and website account are excluded. `languageState(for:)` only reads the saved list, plus transient loading or failure. `loadProviderLanguages(force:)` becomes `refreshProviderLanguages`, called only by **Load Languages**. `validateTranscriptionLanguage` uses the saved list and loads one only when none exists; that happens inside **Transcribe**, which already starts provider work. The five-minute expiry is gone.
- **Picker.** The `.task` is removed. The information popover shows state and **Load Languages**:
  - No list: “Languages for *Provider* aren’t loaded.”
  - Loaded: “Languages updated *date*.”
  - Failed: “Languages Unavailable” followed by the provider's message. The old **Retry** button is replaced by **Load Languages**, so the same action has one label.
  - Provider cannot load: “Turn on Transcription for *Provider* in Settings → Service Providers to load its languages.” or “*Provider* is disabled. Turn it on in Settings → Service Providers to load its languages.”
  - RunPod adds: “Loading languages starts a short RunPod job. RunPod charges apply.”
- **Provider panel.**
  - A **Transcription Languages** section appears for RunPod and website providers, with a status line and **Load Languages**. Status lines: “Not Loaded”, “Loading Languages…”, “*n* languages · Updated *date*”, “Save to load languages.”, “Turn on Enable This Provider to load languages.”, and “Turn on Transcription to load languages.”
  - Automatic checks on open and window focus remain, because they are free and send only credentials. `startCheck` now returns without a request for a disabled provider and shows “Not checked. This provider is disabled.” **Check Connection** is disabled for disabled providers. `ProviderConnectionChecker.check` rejects disabled providers before building a request: “Turn on Enable This Provider to check its connection.”
  - The information popover now reads: “Enabled providers are checked when this panel opens, when you save, and when you choose Check Connection. Checks send credentials, not recordings or meeting text.”
- **Model menu.** New `Services/ProviderModels.swift`:
  - `ProviderModelList` builds the `GET /models` request (logged as “model list”), parses `data[].id` and an optional `name`, skips malformed or duplicate entries, sorts the list, and filters it by ID or name.
  - `ProviderModelListPolicy` decides between none, immediate (an enabled provider's saved configuration), and debounced by 0.8 s (endpoint or key edited). It requires a key and a valid endpoint.
  - The connection check uses the same parser.
  - New `UI/ModelComboBox.swift` wraps `NSComboBox` in data-source mode. Typing filters its menu, and any typed name is kept.
  - The panel shows the saved list immediately, then refreshes in a `.task(id:)` keyed by endpoint, key, and enablement, so typing cancels the pending request. Captions: “Loading Models…”, “Couldn’t load the model list. *reason* Type a model name instead.”, “*model* (not listed)”, and “Enter the endpoint URL and API key to choose from the provider’s models.”
- **Data Privacy.** `PrivacyTrigger.authenticate` is replaced by `.openProvider` (“open the provider in Settings”), `.editProvider` (“edit the provider in Settings”, disabled OpenAI-compatible providers only), and `.loadLanguages` (“choose Load Languages”).
  - Credentials rows merge each provider's content triggers with these. Example: “Sent to RunPod (api.runpod.ai) to authenticate when you transcribe a meeting, open the provider in Settings, or choose Load Languages”.
  - Disabled RunPod, Filedrop, and website providers no longer appear.
  - Joins use a comma when an action already contains “or”.
- **Docs.** The protocol index states the automatic-request rule. The transcription protocol replaces the five-minute client cache with the saved list and explicit **Load Languages**. The summarization protocol describes the model menu. README (language, model, connection checks, and the privacy table) and UI_PREVIEW were updated.
- **Tests.** Coverage added or updated:
  - `ProviderLanguageTests`: saved lists survive a new store; reading state and validating with a saved list start no job; a key change keeps the list; endpoint and model changes invalidate it; Transcribe loads once when none is saved; the RunPod charge note.
  - New `ProviderModelTests`: parsing and fallback, request shape, filtering, listing policy (including disabled providers), cache persistence, pruning, and no endpoint or key in the file; disabled providers of every kind are rejected before any request.
  - `DataPrivacyTests`: new credential wording, and disabled providers.

## Reasoning

- **Explicit trigger for languages: Load Languages, not Save or Check Connection.** Save and Check Connection are understood as free checks. Attaching a billable RunPod job to either would surprise people. A separate button next to a charge note keeps the cost visible. The button appears in the panel and in each picker's popover, so a person who sees an empty picker can act without leaving the task. Website lists use the same action for consistency. Their discovery is free, so an automatic load would be allowed, but it would add a second behavior and another Data Privacy trigger.
- **Transcribe may load a missing list.** Transcribe is an explicit action that submits a billable job. Refusing it until languages are loaded would add a step without reducing surprise.
- **RunPod health for connection checks.** The check already uses `GET {endpoint}/health`. It returns queue and worker counts, starts no worker, and is not billed. Only language discovery needs a job, because the worker computes its list.
- **Checks on open kept for enabled providers.** Under the refined rule they are free and credential-only, and the panel popover and Data Privacy now describe them. Disabled providers are filtered in both `startCheck` and the checker, so neither a UI path nor a future caller can contact them.
- **Fingerprints exclude credentials.** The key does not change a worker's language or model list. Leaving it out avoids storing a derived secret on disk and keeps a list after key rotation.
- **NSComboBox for the model field.** It is the native macOS control for “type a value or choose one”, keeps free text for endpoints without `/models`, and handles arrow keys, Return, and Escape. The data-source mode filters by substring, which prefix completion cannot do for IDs like `openai/gpt-4o`. A SwiftUI popover with a search field and list was rejected: it needs custom focus and arrow-key handling, and it separates typing from the field that holds the value.
- **Rejected:** keeping language lists in `AppSettings`. That would change `Models.swift` and `settings.json`, both of which are being edited concurrently, and would mix fetched data with preferences.

## Technical debt

- **Menu does not open while typing.** `NSComboBox` has no public API to open its menu from code. Typing filters the menu, and the person opens it with the arrow button or the arrow keys. Opening it automatically would require a private selector. Remediation: if testing shows the filter is hard to discover, replace the field with a custom `NSTextField` and an `NSPopover` list.
- **A saved language list can be outdated.** Lists no longer expire. A worker redeployed with fewer languages is detected only when its job fails or the person chooses **Load Languages**. This was accepted to avoid unrequested RunPod jobs. Remediation: show the list's date more prominently if outdated lists cause failures, or use a free worker metadata endpoint if RunPod adds one.
- **Duplicated eligibility rules (retained).** `DataPrivacy.routes` restates the checks in `startCheck`, `ProviderModelListPolicy`, and the language panel. Remediation is unchanged from the Data Privacy worklog: shared `canSend` predicates.

## Notes

- **Read-only libraries.** `ProviderMetadataCache` takes a `canWrite` closure; `MeetingStore` passes `canSave`. With a read-only library, such as one saved by a newer app version, fetched lists stay in memory for the session and no cache file is written. `readOnlyLibraryGainsNoCacheFile` covers this.
- **Concurrent edits.** Only three stored-property lines in `MeetingStore.swift` were changed. Capture, archive, `Models.swift`, and library UI files were not touched.
- **Validation from the repository root.** `make format-macos`, `make lint-macos`, `make test-macos` (183 tests passed; the baseline was 164, and other agents' concurrent tests are included), and `make build-macos-preview` passed. No Swift compiler warnings appeared; the linker search-path warnings existed before this change.
- **Not validated.** No real network requests were made, and nothing was launched on screen. The combo box's keyboard behavior, filtering, and layout in the grouped Form, and the picker popover layout, still need checking in UI Preview.

## Follow-up: built-in RunPod language list

### Problem

Loading RunPod's languages still started a billable `capabilities` job, and the picker stayed empty until someone chose **Load Languages** or **Transcribe** loaded the list. The RunPod worker is built from this repository, so the app can know its list without asking.

### Implemented solution

- **Built-in list.** New `Services/RunPodLanguages.swift` holds 43 languages, including `zh-cn` “Chinese (Simplified)” and `zh-tw` “Chinese (Traditional)”. It is generated by new `apps/worker-audio-extraction/scripts/export-languages.py`, which downloads only the WhisperX wheel pinned in the worker's `uv.lock` (3.8.6), reads `LANGUAGES` and the alignment-model maps as literals, and runs the worker's real `capabilities.transcription_languages()` against them with the default multilingual model. No PyTorch install is needed. The file header names the source, the version, and the regeneration command.
- **No RunPod discovery.** `RunPodProvider.supportedLanguages()`, the `ProviderLanguageListing` protocol, and `workerCatalog` are removed. `ProviderLanguageService.builtInCatalog(for:)` returns the list for RunPod providers, and `languageState(for:)` returns the new `.builtIn` state before reading any cache. `refreshProviderLanguages` ignores RunPod, and `validateTranscriptionLanguage` checks RunPod languages against the built-in list, so **Transcribe** no longer loads a list. Cache writes drop entries saved for RunPod providers before this change.
- **UI.** The picker shows the RunPod list immediately. Its popover shows no load status for RunPod. The provider panel's **Transcription Languages** section shows “43 languages · Built in” for RunPod, including unsaved drafts, with no **Load Languages** button. The note “Loading languages starts a short RunPod job. RunPod charges apply.” is removed. An unlisted language fails with “*Provider* does not support this meeting's language. Choose a listed language.”
- **Website unchanged.** Gday Meetings website providers keep **Load Languages**, the saved list, and loading on **Transcribe** when no list is saved.
- **Data Privacy.** RunPod credentials rows no longer include “choose Load Languages”. Website rows keep it.
- **Docs.** The transcription protocol gains a “RunPod built-in list” section and notes that the Swift app does not send the RunPod `capabilities` request. The protocol index, app README, UI_PREVIEW, and worker README were updated.
- **Tests.** `ProviderLanguageTests` now runs discovery tests against a website provider and adds: the built-in list contains `en`, `zh`, `zh-cn`, and `zh-tw` with the worker's names, is sorted by name, and passes discovery validation; RunPod state, **Load Languages**, and validation never call the loader, and `ProviderLanguageService.catalog` refuses RunPod; an unlisted RunPod language stops before an attempt is created. `DataPrivacyTests` expects the new RunPod credential wording.

### Reasoning

- **Hard-coded list over discovery.** The maintainer chose this because the worker source is in this repository. It removes a billable request and an empty-picker state.
- **Accepted drift.** A deployed worker can differ when it runs older code, another WhisperX version, or an English-only `.en` model. The drift was accepted: an unsupported language fails the transcription job, and the app shows the worker's error. The worker keeps its `capabilities` operation for the website and other clients.
- **Swift array over a JSON resource.** A generated Swift file needs no resource bundle in the executable target and builds with the Command Line Tools SwiftPM toolchain.
- **Running the worker's own function.** The export script stubs only the `whisperx` metadata modules and calls `capabilities.py`, so filtering, title casing, the Chinese variants, and sorting are not reimplemented.

### Technical debt

- **Manual regeneration.** Nothing fails when `capabilities.py` or the WhisperX pin changes without rerunning the export script. Consequence: the app list can drift from the worker in this repository, not only from deployed workers. Remediation: add a worker test or CI step that runs the script and compares its output with `RunPodLanguages.swift`.
- **Orphaned RunPod cache entries.** Entries saved before this change stay in `provider-languages.json` until the next website list is saved. They are never read. No remediation is planned.

### Notes

- **Validation from the repository root.** `make format-macos`, `make lint-macos`, `make test-macos` (186 tests passed; the baseline was 183), and `make build-macos-preview` passed. The export script's output matches the checked-in file. No Swift compiler warnings appeared; the linker search-path warnings existed before this change.
- **Not validated.** No RunPod requests were made, and nothing was launched on screen. The provider panel section and picker popover still need checking in UI Preview.

## Follow-up: name the language source

The language information popover now names the provider whenever the menu has choices: “Languages from *Provider*, included with Gday Meetings.” for RunPod’s built-in list, and “Languages from *Provider*, updated *date*.” for a loaded list. This replaces “Languages updated *date*.” and the previously empty built-in state. Technical debt: None.

## Follow-up: shorter RunPod language list

The user chose the Rust client's 11 languages for RunPod: English, Chinese (Simplified), Chinese (Traditional), Japanese, Korean, Spanish, French, German, Portuguese, Russian, and Arabic, in that order. `export-languages.py` now filters the worker's list to `OFFERED` in display order and exits with an error if the worker stops supporting one of them, so the list stays a verified subset. Technical debt: None.
