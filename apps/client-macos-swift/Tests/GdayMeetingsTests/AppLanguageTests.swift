import Foundation
import Testing

@testable import GdayMeetings

struct AppLanguageTests {
    @Test func standardChoicesKeepLanguagesAndOneEnglish() {
        #expect(AppLanguages.all.count == 13)
        #expect(AppLanguages.all.filter { $0.code.hasPrefix("en") }.map(\.code) == ["en"])
        #expect(Set(RunPodLanguages.all.map(\.code)).isSubset(of: Set(AppLanguages.all.map(\.code))))
        #expect(AppLanguages.all.contains { $0.code == "it" })
        #expect(AppLanguages.all.contains { $0.code == "yue" })
        #expect(AppLanguages.canonicalCode(for: "en_AU") == "en")
        #expect(AppLanguages.canonicalCode(for: "zh-Hans") == "zh-cn")
        #expect(AppLanguages.canonicalCode(for: "zh_Hant_TW") == "zh-tw")
        #expect(AppLanguages.canonicalCode(for: "zh") == nil)
        #expect(AppLanguages.canonicalCode(for: "cy") == nil)
    }
    @Test func providerMappingPreservesScriptAndUsesExplicitEquivalents() {
        func catalog(_ codes: [String]) -> ProviderLanguageCatalog {
            .init(languages: codes.map { .init(code: $0, name: $0) }, source: "Test")
        }
        #expect(AppLanguages.providerCode(for: "en", catalog: catalog(["en-au", "en-us"])) == "en-us")
        #expect(AppLanguages.providerCode(for: "en", catalog: catalog(["en-au"])) == nil)
        #expect(AppLanguages.providerCode(for: "zh-cn", catalog: catalog(["zh", "zh-hant"])) == nil)
        #expect(AppLanguages.providerCode(for: "zh-tw", catalog: catalog(["zh-hans", "zh-hant"])) == "zh-hant")
        #expect(AppLanguages.providerCode(for: "zh-Hans", catalog: catalog(["zh-cn"])) == "zh-cn")
        #expect(AppLanguages.providerCode(for: "it", catalog: catalog(["it-it"])) == "it-it")
        #expect(AppLanguages.providerCode(for: "cy", catalog: catalog(["cy"])) == "cy")
    }
    @Test func attemptKeepsMeetingAndProviderCodesSeparately() throws {
        let provider = ServiceProvider(kind: .gdayWebsite)
        let meeting = Meeting(title: "Language", language: "zh-tw")
        var attempt = ProviderTranscriptionAttempt(provider: provider, meeting: meeting)
        attempt.providerLanguage = "zh-hant"
        let data = try JSONEncoder().encode(attempt)
        let restored = try JSONDecoder().decode(ProviderTranscriptionAttempt.self, from: data)
        #expect(restored.language == "zh-tw")
        #expect(restored.providerLanguage == "zh-hant")
        #expect(meeting.language == "zh-tw")
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "providerLanguage")
        let legacy = try JSONDecoder().decode(
            ProviderTranscriptionAttempt.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.providerLanguage == nil)
        #expect(legacy.language == "zh-tw")
    }
    @Test @MainActor func unsupportedStandardChoiceStopsBeforeUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let provider = ServiceProvider(kind: .runpod)
        store.settings.serviceProviders = [provider]
        let id = store.createMeeting(title: "Italian", language: "it")
        await #expect(throws: (any Error).self) { try await store.transcribeWithProvider(id: id, provider: provider) }
        #expect(store.meetings.first?.transcriptionAttempt == nil)
        #expect(store.meetings.first?.language == "it")
    }
    @Test @MainActor func websiteResolvesOnceAndPinnedCodeCannotRemap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        var provider = ServiceProvider(kind: .gdayWebsite)
        provider.enabledCapabilities = [.transcription]
        store.settings.serviceProviders = [provider]
        var requests = 0
        store.providerLanguageLoader = { _ in
            requests += 1
            return .init(languages: [.init(code: "en-us", name: "English")], source: "Website")
        }
        #expect(try await store.resolvedTranscriptionLanguage("en", for: provider) == "en-us")
        #expect(
            try await store.resolvedTranscriptionLanguage("en-us", for: provider, preservingRequestCode: true)
                == "en-us")
        await #expect(throws: (any Error).self) {
            try await store.resolvedTranscriptionLanguage("en", for: provider, preservingRequestCode: true)
        }
        #expect(requests == 1)
    }
}
