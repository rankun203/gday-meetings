import Foundation
import Testing

@testable import GdayMeetings

struct SummaryPromptTests {
    @Test func requestInstructionsOverrideLanguageWithoutChangingMeetingOrProvider() throws {
        let provider = ServiceProvider(kind: .openAICompatible)
        var meeting = Meeting()
        meeting.language = "zh"
        meeting.notes = "Discuss the release."
        let now = Date(timeIntervalSince1970: 0)
        let baseline = SummaryPrompt.messages(provider: provider, meeting: meeting, people: [], now: now)
        let messages = SummaryPrompt.messages(
            provider: provider, meeting: meeting, people: [], now: now, instructions: "  Write in English.\n")
        #expect(messages[0].content.contains("## User Instructions"))
        #expect(messages[0].content.contains("take precedence over the default language"))
        #expect(messages[0].content.hasSuffix("Write in English."))
        #expect(messages[1].content == baseline[1].content)
        #expect(provider.summaryPrompt == SummaryPrompt.defaultInstructions)
        #expect(meeting.language == "zh")
        let blank = SummaryPrompt.messages(
            provider: provider, meeting: meeting, people: [], now: now, instructions: " \n ")
        #expect(blank[0].content == baseline[0].content)
    }

    @Test func taskInstructionsRoundTripAndOlderTasksDecode() throws {
        var task = ManagedTaskRecord(kind: .summary, meetingID: UUID(), meetingTitle: "Planning")
        task.summaryInstructions = "Write in English."
        let encoded = try JSONEncoder().encode(task)
        let restored = try JSONDecoder().decode(ManagedTaskRecord.self, from: encoded)
        #expect(restored.summaryInstructions == task.summaryInstructions)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "summaryInstructions")
        let old = try JSONDecoder().decode(
            ManagedTaskRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.summaryInstructions == nil)
    }

    @Test func providersUseRustDefaultAndRoundTripCustomPrompt() throws {
        var provider = ServiceProvider(kind: .openAICompatible)
        let data = try JSONEncoder().encode(provider)
        let restored = try JSONDecoder().decode(ServiceProvider.self, from: data)
        #expect(restored.summaryPrompt == SummaryPrompt.defaultInstructions)
        provider.summaryPrompt = "Only list decisions."
        let custom = try JSONDecoder().decode(ServiceProvider.self, from: JSONEncoder().encode(provider))
        #expect(custom.summaryPrompt == "Only list decisions.")
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
