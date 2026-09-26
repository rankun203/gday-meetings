import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ProviderLanguageTests {
    private func makeStore() -> MeetingStore {
        MeetingStore(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    /// Discovery tests use the website, the only provider whose list is loaded.
    private func provider(_ name: String, kind: ServiceProviderKind = .gdayWebsite) -> ServiceProvider {
        var provider = ServiceProvider(kind: kind)
        provider.name = name
        provider.endpoint = "https://example.test/\(name)"
        provider.enabledCapabilities = [.transcription]
        return provider
    }

    @Test func listsAreProviderOwnedAndCacheTracksConfiguration() async throws {
        let store = makeStore()
        var first = provider("First")
        let second = provider("Second")
        store.settings.serviceProviders = [first, second]
        var calls = 0
        store.providerLanguageLoader = { selected in
            calls += 1
            let code = selected.id == first.id ? "ja" : "zh"
            return ProviderLanguageCatalog(languages: [.init(code: code, name: code)], source: selected.name)
        }
        await store.refreshProviderLanguages(providerID: first.id)
        await store.refreshProviderLanguages(providerID: second.id)
        guard case .loaded(let firstList, _) = store.languageState(for: first.id),
            case .loaded(let secondList, _) = store.languageState(for: second.id)
        else {
            Issue.record("Expected provider language lists")
            return
        }
        #expect(firstList.languages.map(\.code) == ["ja"])
        #expect(secondList.languages.map(\.code) == ["zh"])
        // Load Languages is explicit, so it always asks the provider again.
        await store.refreshProviderLanguages(providerID: first.id)
        #expect(calls == 3)
        // A new key reaches the same worker, so the saved list still applies.
        first.apiKey = "new-key"
        store.settings.serviceProviders[0] = first
        guard case .loaded = store.languageState(for: first.id) else {
            Issue.record("A changed key must keep the saved list")
            return
        }
        for change in ["endpoint", "model"] {
            if change == "endpoint" {
                first.endpoint += "/changed"
            }
            else {
                first.model = "new-model"
            }
            store.settings.serviceProviders[0] = first
            #expect(store.languageState(for: first.id) == .idle)
        }
        #expect(calls == 3)
    }

    @Test func readingLanguagesNeverContactsTheProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = provider("Website")
        let first = MeetingStore(dataDirectory: directory)
        first.settings.serviceProviders = [selected]
        var jobs = 0
        first.providerLanguageLoader = { _ in
            jobs += 1
            return ProviderLanguageCatalog(languages: [.init(code: "en", name: "English")], source: "Worker")
        }
        // Without a saved list, reading provider support must not send a request.
        #expect(first.languageState(for: selected.id) == .idle)
        #expect(jobs == 0)
        await first.refreshProviderLanguages(providerID: selected.id)
        #expect(jobs == 1)

        // A later launch reads the saved list; validation sends no request.
        let second = MeetingStore(dataDirectory: directory)
        second.settings.serviceProviders = [selected]
        second.providerLanguageLoader = { _ in
            Issue.record("A saved list must not be loaded again")
            throw ServiceError("Unexpected request")
        }
        guard case .loaded(let catalog, _) = second.languageState(for: selected.id) else {
            Issue.record("Expected the saved list")
            return
        }
        #expect(catalog.languages.map(\.code) == ["en"])
        try await second.validateTranscriptionLanguage("en", for: selected)
    }

    @Test func runpodUsesTheBuiltInWorkerList() throws {
        let catalog = try #require(ProviderLanguageService.builtInCatalog(for: provider("RunPod", kind: .runpod)))
        let names = Dictionary(uniqueKeysWithValues: catalog.languages.map { ($0.code, $0.name) })
        #expect(names["zh-cn"] == "Chinese (Simplified)")
        #expect(names["zh-tw"] == "Chinese (Traditional)")
        // The offered subset keeps its display order; it must also pass the discovery schema checks.
        #expect(
            catalog.languages.map(\.code) == ["en", "zh-cn", "zh-tw", "ja", "ko", "es", "fr", "de", "pt", "ru", "ar"])
        let entries = catalog.languages.map { ["code": $0.code, "name": $0.name] }
        #expect(try ProviderLanguageService.parseLanguages(entries, source: "RunPod") == catalog)
        #expect(ProviderLanguageService.builtInCatalog(for: provider("Website")) == nil)
    }

    @Test func runpodNeverLoadsLanguages() async throws {
        let store = makeStore()
        var selected = provider("RunPod", kind: .runpod)
        store.settings.serviceProviders = [selected]
        store.providerLanguageLoader = { _ in
            Issue.record("RunPod languages must never be loaded")
            throw ServiceError("Unexpected request")
        }
        // Provider support is available immediately, even before a key is entered.
        guard case .builtIn(let catalog) = store.languageState(for: selected.id) else {
            Issue.record("Expected the built-in RunPod list")
            return
        }
        #expect(catalog.languages.contains { $0.code == "zh-tw" })
        await store.refreshProviderLanguages(providerID: selected.id)
        try await store.validateTranscriptionLanguage("zh-cn", for: selected)
        await #expect(throws: (any Error).self) { try await ProviderLanguageService.catalog(for: selected) }
        // The list does not depend on the endpoint or model.
        selected.endpoint += "/changed"
        selected.model = "other"
        store.settings.serviceProviders[0] = selected
        #expect(store.languageState(for: selected.id) == .builtIn(catalog))
        #expect(store.providerLanguageStates.isEmpty)
        #expect(store.providerLanguageCache.entries.isEmpty)
    }

    @Test func runpodRejectsUnlistedLanguageBeforeUpload() async throws {
        let store = makeStore()
        let selected = provider("RunPod", kind: .runpod)
        store.settings.serviceProviders = [selected]
        let id = store.createMeeting(title: "Welsh meeting", language: "cy")
        do {
            try await store.transcribeWithProvider(id: id, provider: selected)
            Issue.record("An unlisted language must stop transcription")
        }
        catch {
            #expect(
                error.localizedDescription
                    .contains("does not support"))
        }
        #expect(store.meetings.first?.transcriptionAttempt == nil)
    }

    @Test func transcribeLoadsLanguagesOnceWhenNoneAreSaved() async throws {
        let store = makeStore()
        let selected = provider("Worker")
        store.settings.serviceProviders = [selected]
        var calls = 0
        store.providerLanguageLoader = { _ in
            calls += 1
            return ProviderLanguageCatalog(languages: [.init(code: "en", name: "English")], source: "Worker")
        }
        try await store.validateTranscriptionLanguage("en", for: selected)
        try await store.validateTranscriptionLanguage("en", for: selected)
        #expect(calls == 1)
    }

    @Test func unsupportedLanguageStopsBeforeAudioOrJobSubmission() async throws {
        let store = makeStore()
        let selected = provider("Japanese")
        store.settings.serviceProviders = [selected]
        store.providerLanguageLoader = { _ in
            ProviderLanguageCatalog(languages: [.init(code: "ja", name: "Japanese")], source: "Worker")
        }
        let id = store.createMeeting(title: "English meeting", language: "en")
        do {
            try await store.transcribeWithProvider(id: id, provider: selected)
            Issue.record("Unsupported language must stop transcription")
        }
        catch {
            #expect(error.localizedDescription.contains("does not support"))
        }
        #expect(store.meetings.first?.transcriptionAttempt == nil)
    }

    @Test func unavailableIsNotAnUnsupportedLanguageAndCanRetry() async {
        let store = makeStore()
        let selected = provider("Unavailable")
        store.settings.serviceProviders = [selected]
        var calls = 0
        store.providerLanguageLoader = { _ in
            calls += 1
            throw ServiceError("Worker unavailable")
        }
        await store.refreshProviderLanguages(providerID: selected.id)
        #expect(store.languageState(for: selected.id) == .failed("Worker unavailable"))
        await store.refreshProviderLanguages(providerID: selected.id)
        #expect(calls == 2)
    }

    @Test func savedResultDoesNotRequireLanguageDiscovery() async throws {
        let store = makeStore()
        let selected = provider("Offline")
        store.settings.serviceProviders = [selected]
        store.providerLanguageLoader = { _ in
            Issue.record("A saved result must not discover languages")
            throw ServiceError("Offline")
        }
        let id = store.createMeeting(title: "Saved result")
        var meeting = try #require(store.meetings.first)
        meeting.transcriptionAttempt = ProviderTranscriptionAttempt(provider: selected, meeting: meeting)
        meeting.transcriptionAttempt?.result = [TranscriptSegment(text: "Saved")]
        store.updateMeeting(meeting)
        try await store.transcribeWithProvider(id: id, provider: selected)
        #expect(store.meetings.first?.transcript.first?.text == "Saved")
    }

    @Test func pendingJobPollDoesNotRequireLanguageDiscovery() async throws {
        let store = makeStore()
        let selected = provider("Pending", kind: .runpod)
        store.settings.serviceProviders = [selected]
        store.providerLanguageLoader = { _ in
            Issue.record("An existing task must not discover languages")
            throw ServiceError("Unavailable")
        }
        let id = store.createMeeting(title: "Pending task")
        var meeting = try #require(store.meetings.first)
        meeting.transcriptionAttempt = ProviderTranscriptionAttempt(provider: selected, meeting: meeting)
        meeting.transcriptionAttempt?.taskID = "existing-job"
        store.updateMeeting(meeting)
        do {
            try await store.transcribeWithProvider(id: id, provider: selected)
            Issue.record("Missing poll credentials should fail")
        }
        catch {
            #expect(error.localizedDescription.contains("API key is missing"))
        }
    }

    @Test func inFlightDiscoveryRejectsChangedProviderForEveryCaller() async throws {
        let store = makeStore()
        var selected = provider("Changing")
        store.settings.serviceProviders = [selected]
        var continuation: CheckedContinuation<ProviderLanguageCatalog, Error>?
        store.providerLanguageLoader = { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let original = selected
        let first = Task { try await store.validateTranscriptionLanguage("en", for: original) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        let second = Task { try await store.validateTranscriptionLanguage("en", for: original) }
        await Task.yield()
        selected.endpoint += "/changed"
        store.settings.serviceProviders[0] = selected
        pending.resume(
            returning: ProviderLanguageCatalog(languages: [.init(code: "en", name: "English")], source: "Old"))
        for task in [first, second] {
            do {
                try await task.value
                Issue.record("Changed provider should reject the old catalog")
            }
            catch { #expect(error.localizedDescription.contains("settings changed")) }
        }
        #expect(store.languageState(for: selected.id) == .idle)
    }

    @Test func discoveredListsAreValidated() throws {
        let entries = [["code": "cy", "name": "Welsh"]]
        #expect(try ProviderLanguageService.parseLanguages(entries, source: "Website").languages.map(\.code) == ["cy"])
        #expect(throws: (any Error).self) { try ProviderLanguageService.parseLanguages(nil, source: "Old website") }
        #expect(throws: (any Error).self) { try ProviderLanguageService.parseLanguages([], source: "Unavailable") }
        #expect(throws: (any Error).self) {
            try ProviderLanguageService.parseLanguages([["code": "auto", "name": "Automatic"]], source: "Worker")
        }
    }
}
