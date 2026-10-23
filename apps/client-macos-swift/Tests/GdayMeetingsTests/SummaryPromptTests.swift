import Foundation
import Testing

@testable import GdayMeetings

struct SummaryPromptTests {
    @Test(arguments: [false, true])
    func audioSourcesRemainTranscriptContextRatherThanParticipants(storedMetadata: Bool) {
        let person = Person(name: "Alex")
        let namedSpeaker = MeetingSpeaker(
            label: "sys_01", track: "system", providerName: "Synthetic", personID: person.id)
        var sourceSpeaker = MeetingSpeaker(label: "sys", track: "system", providerName: "Synthetic")
        sourceSpeaker.sourcePlaceholder = .system
        var meeting = Meeting(title: "Planning")
        meeting.speakers = [namedSpeaker] + (storedMetadata ? [sourceSpeaker] : [])
        meeting.transcript = [
            .init(start: 0, end: 2, speaker: "sys_01", text: "I will prepare the draft.", speakerID: namedSpeaker.id),
            .init(
                start: 2, end: 3, speaker: "sys", text: "And send it tomorrow.",
                speakerID: storedMetadata ? sourceSpeaker.id : nil,
                source: .system, sourcePlaceholder: storedMetadata ? true : nil),
            .init(start: 4, end: 5, speaker: "mic", text: "Thank you.", source: .microphone),
        ]
        var provider = ServiceProvider(kind: .openAICompatible)
        provider.summaryPrompt = "List decisions."
        let messages = SummaryPrompt.messages(provider: provider, meeting: meeting, people: [person])
        let context = messages[1].content
        #expect(messages[0].content.hasPrefix("List decisions.\n"))
        #expect(context.contains("Participants: Alex\n"))
        #expect(context.contains("[00:02] sys: And send it tomorrow."))
        #expect(context.contains("[00:04] mic: Thank you."))
        #expect(context.components(separatedBy: "Unidentified-speaker labels").count == 2)
        #expect(context.contains("Unidentified-speaker labels (mic, sys) mark speech without a recognized person."))
        #expect(context.contains("Each source can contain several people"))
        #expect(context.contains("Infer a speaker from surrounding lines only when the context supports it."))
        #expect(context.contains("Keep the speaker unidentified or state uncertainty"))
    }

    @Test func detectedSpeakerLabelsRemainDistinctFromAudioSources() {
        var meeting = Meeting(title: "Planning")
        meeting.transcript = [
            .init(start: 0, end: 2, speaker: "sys_01", text: "Choose a date."),
            .init(start: 3, end: 5, speaker: "mic_01", text: "Next week."),
        ]
        let context = SummaryPrompt.messages(
            provider: ServiceProvider(kind: .openAICompatible), meeting: meeting, people: [])[1].content
        #expect(context.contains("Participants: mic_01, sys_01\n"))
        #expect(!context.contains("Unidentified-speaker labels"))
    }

    @Test func includesCertainAndTentativeParticipantsWithTheirNotes() {
        var certain = Person(name: "Alex")
        certain.notes = "Coordinates scheduling."
        var tentative = Person(name: "Sam")
        tentative.notes = "Maintains release notes."
        let unassociated = Person(name: "Taylor")
        let certainSpeaker = MeetingSpeaker(
            label: "mic_01", track: "microphone", providerName: "Synthetic", personID: certain.id)
        var tentativeSpeaker = MeetingSpeaker(
            label: "sys_01", track: "system", providerName: "Synthetic", personID: tentative.id)
        tentativeSpeaker.voiceReviewOrigin = .init(
            speakerID: tentativeSpeaker.id, transcriptAssociationTier: .tentative)
        var meeting = Meeting(title: "Planning")
        meeting.speakers = [certainSpeaker, tentativeSpeaker]
        meeting.transcript = [
            .init(start: 0, end: 2, speaker: "mic_01", text: "Choose a date.", speakerID: certainSpeaker.id),
            .init(start: 3, end: 5, speaker: "sys_01", text: "I will draft notes.", speakerID: tentativeSpeaker.id),
        ]
        let context = SummaryPrompt.messages(
            provider: ServiceProvider(kind: .openAICompatible), meeting: meeting,
            people: [certain, tentative, unassociated])[1].content
        #expect(context.contains("Participants: Alex, Sam ?\n"))
        #expect(context.contains("Alex: Coordinates scheduling."))
        #expect(context.contains("Sam ?: Maintains release notes."))
        #expect(context.contains("[00:03] Sam ?: I will draft notes."))
        #expect(context.components(separatedBy: "A name followed by `?`").count == 2)
        #expect(context.contains("preserve `?` whenever attributing speech or actions"))
        #expect(!context.contains(unassociated.name))
    }

    @Test(arguments: [false, true])
    func independentAttendanceRetainsCertainParticipantContextWithTentativeSpeech(storedAttendance: Bool) {
        var person = Person(name: "Alex")
        person.notes = "Coordinates scheduling."
        var speaker = MeetingSpeaker(
            label: "sys_01", track: "system", providerName: "Synthetic", personID: person.id)
        speaker.voiceReviewOrigin = .init(speakerID: speaker.id, transcriptAssociationTier: .tentative)
        var meeting = Meeting(title: "Planning")
        if storedAttendance { meeting.personIDs = [person.id] }
        meeting.speakers = [speaker]
        if !storedAttendance {
            meeting.speakers.append(
                MeetingSpeaker(label: "sys_02", track: "system", providerName: "Synthetic", personID: person.id))
        }
        meeting.transcript = [
            .init(start: 0, end: 2, speaker: "sys_01", text: "Choose a date.", speakerID: speaker.id)
        ]
        let context = SummaryPrompt.messages(
            provider: ServiceProvider(kind: .openAICompatible), meeting: meeting, people: [person])[1].content
        #expect(context.contains("Participants: Alex\n"))
        #expect(context.contains("Alex: Coordinates scheduling."))
        #expect(context.contains("[00:00] Alex ?: Choose a date."))
        #expect(meeting.speakerName(for: meeting.transcript[0], people: [person]) == "Alex (Tentative)")
    }

    @Test func strongSpeakerWithoutCurrentRowsKeepsCertainParticipantContext() {
        var person = Person(name: "Alex")
        person.notes = "Coordinates scheduling."
        var meeting = Meeting(title: "Planning")
        meeting.speakers = [
            MeetingSpeaker(label: "sys_01", track: "system", providerName: "Synthetic", personID: person.id)
        ]
        let context = SummaryPrompt.messages(
            provider: ServiceProvider(kind: .openAICompatible), meeting: meeting, people: [person])[1].content
        #expect(context.contains("Participants: Alex\n"))
        #expect(context.contains("Alex: Coordinates scheduling."))
        #expect(!context.contains("Alex ?"))
        #expect(!context.contains("low-confidence speaker association"))
    }

    @Test func certainAndLegacyNamesNeedNoAssociationExplanation() {
        let person = Person(name: "Alex")
        var meeting = Meeting(title: "Planning")
        meeting.personIDs = [person.id]
        meeting.transcript = [.init(start: 0, end: 2, speaker: "Sam", text: "Choose a date.")]
        let context = SummaryPrompt.messages(
            provider: ServiceProvider(kind: .openAICompatible), meeting: meeting, people: [person])[1].content
        #expect(context.contains("Participants: Alex, Sam\n"))
        #expect(!context.contains("low-confidence speaker association"))
    }

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
