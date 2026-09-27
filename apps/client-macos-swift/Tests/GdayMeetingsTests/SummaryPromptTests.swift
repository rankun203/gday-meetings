import Foundation
import Testing

@testable import GdayMeetings

struct SummaryPromptTests {
    @Test func oldProvidersUseRustDefaultAndRoundTripCustomPrompt() throws {
        var provider = ServiceProvider(kind: .openAICompatible)
        let oldData = try JSONEncoder().encode(provider)
        let restored = try JSONDecoder().decode(ServiceProvider.self, from: oldData)
        #expect(restored.summaryPrompt == SummaryPrompt.defaultInstructions)
        provider.summaryPrompt = "Only list decisions."
        let custom = try JSONDecoder().decode(ServiceProvider.self, from: JSONEncoder().encode(provider))
        #expect(custom.summaryPrompt == "Only list decisions.")
    }

    @Test func legacyCustomPromptMigratesOnlyToSelectedProvider() throws {
        let selected = ServiceProvider(kind: .openAICompatible)
        let other = ServiceProvider(kind: .openAICompatible)
        var settings = AppSettings()
        settings.serviceProviders = [selected, other]
        settings.summaryProviderID = selected.id
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["summarizationPrompt"] = "Keep it brief."
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated.serviceProviders[0].summaryPrompt == "Keep it brief.")
        #expect(migrated.serviceProviders[1].summaryPrompt == SummaryPrompt.defaultInstructions)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
        #expect(encoded["summarizationPrompt"] == nil)
    }

    @Test func legacyStockPromptUsesRustDefaultAndProviderCustomWinsMigration() throws {
        var provider = ServiceProvider(kind: .openAICompatible)
        var settings = AppSettings()
        settings.summaryProviderID = provider.id
        settings.serviceProviders = [provider]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["summarizationPrompt"] =
            "Summarize this meeting with decisions, key points, and action items. Do not invent information."
        var restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.serviceProviders[0].summaryPrompt == SummaryPrompt.defaultInstructions)
        provider.summaryPrompt = "Provider instructions."
        settings.serviceProviders = [provider]
        json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["summarizationPrompt"] = "Old global instructions."
        restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.serviceProviders[0].summaryPrompt == "Provider instructions.")
        #expect(restored.pendingSummaryPromptMigration == "Old global instructions.")
    }

    @Test func dormantLegacyPromptMovesToUnselectedLLMProvider() throws {
        let provider = ServiceProvider(kind: .openAICompatible)
        var settings = AppSettings()
        settings.serviceProviders = [ServiceProvider(kind: .runpod), provider]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["summarizationPrompt"] = "Dormant instructions."
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.summaryProviderID == nil)
        #expect(restored.serviceProviders[1].summaryPrompt == "Dormant instructions.")
        #expect(restored.pendingSummaryPromptMigration == nil)
    }

    @Test func dormantLegacyPromptSurvivesWithoutProvidersAndMigratesLater() throws {
        let data = Data(#"{"summarizationPrompt":"Keep these instructions."}"#.utf8)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(restored.pendingSummaryPromptMigration == "Keep these instructions.")
        var savedAgain = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(restored))
        #expect(savedAgain.pendingSummaryPromptMigration == "Keep these instructions.")
        savedAgain.serviceProviders.append(ServiceProvider(kind: .openAICompatible))
        savedAgain.migratePendingSummaryPrompt()
        #expect(savedAgain.serviceProviders[0].summaryPrompt == "Keep these instructions.")
        #expect(savedAgain.pendingSummaryPromptMigration == nil)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(savedAgain))
        #expect(migrated.serviceProviders[0].summaryPrompt == "Keep these instructions.")
        #expect(migrated.pendingSummaryPromptMigration == nil)
    }

    @Test func summaryRequestUsesProviderPromptAndCitableMeetingContext() throws {
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.summaryPrompt = "List decisions with citations."
        var meeting = Meeting()
        meeting.title = "Planning"
        meeting.language = "zh"
        meeting.duration = 125
        meeting.notes = "Ship next week."
        meeting.summary = "Old generated text must not become evidence."
        meeting.transcript = [.init(start: 75, end: 80, speaker: "Alex", text: "I will send the release notes.")]
        let messages = SummaryPrompt.messages(
            provider: provider, meeting: meeting, people: [], now: Date(timeIntervalSince1970: 0))
        #expect(messages.count == 2)
        #expect(messages[0].role == "system")
        #expect(messages[0].content.hasPrefix("List decisions with citations.\n\nLanguage: zh\nCurrent time:"))
        #expect(!messages[0].content.contains("Include explicit action items"))
        #expect(messages[1].content.contains("Duration: 2m 5s"))
        #expect(messages[1].content.contains("[01:15] Alex: I will send the release notes."))
        #expect(messages[1].content.contains("Ship next week."))
        #expect(!messages[1].content.contains(meeting.summary))
    }
}
