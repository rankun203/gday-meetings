import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct SpeakerRecognitionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func provider() -> ServiceProvider {
        var value = ServiceProvider(kind: .runpod)
        value.endpoint = "https://api.runpod.ai/v2/synthetic"
        value.enabledCapabilities = [.transcription, .diarization]
        return value
    }

    @Test func providerPreservesTrackScopedLabelsAndValidVoiceData() throws {
        let result: [String: Any] = [
            "status": "COMPLETED",
            "output": [
                "tracks": [
                    "microphone": [
                        "segments": [["start": 0.0, "end": 1.0, "text": "One", "speaker": "SPEAKER_00"]],
                        "speaker_embeddings": ["SPEAKER_00": [1.0, 0.0]],
                    ],
                    "system": [
                        "segments": [["start": 1.0, "end": 2.0, "text": "Two", "speaker": "SPEAKER_00"]],
                        "speaker_embeddings": ["SPEAKER_00": [Double.nan, 1.0]],
                    ],
                ]
            ],
        ]
        guard case .complete(let segments) = try RunPodProvider.parseStatus(result) else {
            Issue.record("Expected completed transcript")
            return
        }
        #expect(segments.count == 2)
        #expect(segments[0].embedding == [1, 0])
        #expect(segments[1].embedding == nil)
        let recognized = SpeakerRecognition.result(
            segments, attempt: .init(provider: provider(), meeting: Meeting()), people: [])
        #expect(recognized.speakers.count == 2)
        #expect(recognized.segments[0].speakerID != recognized.segments[1].speakerID)
        #expect(recognized.speakers.allSatisfy { $0.personID == nil && !$0.confirmed })
    }

    @Test func assigningReassigningAndRemovingPersistWithoutDuplicatingSamples() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let first = store.addPerson(name: "Alex")
        let second = store.addPerson(name: "Sam")
        var meeting = Meeting(title: "Speaker assignment")
        let speaker = MeetingSpeaker(
            label: "SPEAKER_00", track: "system", providerName: "RunPod",
            voiceScope: "runpod:test", embedding: [1, 0])
        meeting.speakers = [speaker]
        meeting.transcript = [.init(speaker: speaker.label, text: "Hello", speakerID: speaker.id)]
        try store.insertImportedMeeting(meeting)
        store.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: first)
        store.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: first)
        #expect(store.people.first { $0.id == first }?.voiceSamples.count == 1)
        store.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: second)
        #expect(store.people.first { $0.id == first }?.voiceSamples.isEmpty == true)
        #expect(store.people.first { $0.id == second }?.voiceSamples.count == 1)
        let reopened = MeetingStore(dataDirectory: root)
        _ = try #require(reopened.meeting(id: meeting.id))
        let saved = try #require(reopened.meetings.first)
        #expect(saved.personIDs == [second])
        #expect(saved.speakerName(for: saved.transcript[0], people: reopened.people) == "Sam")
        #expect(saved.transcript[0].speaker == "SPEAKER_00")
        reopened.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: nil)
        #expect(reopened.meetings.first?.personIDs.isEmpty == true)
        #expect(reopened.people.allSatisfy { $0.voiceSamples.isEmpty })
        #expect(reopened.meetings.first?.speakers[0].personID == nil)
    }

    @Test func recognitionUsesOnlyCompatibleAssignedSamplesAndOnePersonPerTrack() {
        let person = Person(
            name: "Alex",
            voiceSamples: [
                .init(meetingID: UUID(), speakerID: UUID(), scope: "runpod:test", embedding: [1, 0])
            ])
        var speakers = [
            MeetingSpeaker(
                label: "A", track: "system", providerName: "RunPod", voiceScope: "runpod:test", embedding: [1, 0]),
            MeetingSpeaker(
                label: "B", track: "system", providerName: "RunPod", voiceScope: "runpod:test", embedding: [0.99, 0.01]),
            MeetingSpeaker(
                label: "C", track: "mic", providerName: "RunPod", voiceScope: "runpod:test", embedding: [1, 0]),
            MeetingSpeaker(
                label: "D", track: "other", providerName: "RunPod", voiceScope: "runpod:different", embedding: [1, 0]),
            MeetingSpeaker(
                label: "E", track: "other", providerName: "RunPod", voiceScope: "runpod:test", embedding: [0, 1]),
            MeetingSpeaker(
                label: "F", track: "other", providerName: "RunPod", voiceScope: "runpod:test", embedding: [1, 0, 0]),
        ]
        SpeakerRecognition.match(&speakers, people: [person])
        #expect(speakers[0].personID == person.id)
        #expect(speakers[1].personID == nil)
        #expect(speakers[2].personID == person.id)
        #expect(speakers.dropFirst(3).allSatisfy { $0.personID == nil })
        #expect(speakers.allSatisfy { $0.confirmed == ($0.personID != nil) })
        #expect(SpeakerRecognition.similarity([0, 0], [1, 0]) == nil)
        #expect(SpeakerRecognition.similarity([.infinity], [1]) == nil)
    }

    @Test func existingAutomaticMatchLoadsAsAssignedWithoutLearningItsVoice() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let personID = store.addPerson(name: "Alex")
        var meeting = Meeting(title: "Automatic match")
        let speaker = MeetingSpeaker(
            label: "sys_SPEAKER_01", track: "system", providerName: "RunPod",
            voiceScope: "runpod:test", embedding: [1, 0], personID: personID, confidence: 0.91)
        // File imports may contain a person assignment without the derived
        // meeting association. Loading normalizes the association.
        meeting.speakers = [speaker]
        meeting.transcript = [.init(speaker: speaker.label, text: "Hello", speakerID: speaker.id)]
        try store.insertImportedMeeting(meeting)
        let reopened = MeetingStore(dataDirectory: root)
        _ = try #require(reopened.meeting(id: meeting.id))
        let saved = try #require(reopened.meetings.first)
        #expect(saved.personIDs == [personID])
        #expect(saved.speakers == meeting.speakers)
        #expect(saved.speakerName(for: saved.transcript[0], people: reopened.people) == "Alex")
        #expect(reopened.people[0].voiceSamples.isEmpty)
        let markdown = root.appendingPathComponent("automatic.md")
        try reopened.exportMeeting(id: meeting.id, to: markdown)
        #expect(try String(contentsOf: markdown, encoding: .utf8).contains("**Alex:** Hello"))
        reopened.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: nil)
        #expect(reopened.meetings[0].personIDs.isEmpty)
        #expect(reopened.people[0].voiceSamples.isEmpty)
    }

    @Test func assigningWhileTranscribingPreservesSavedResultForExplicitReplacement() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let person = store.addPerson(name: "Alex")
        var meeting = Meeting()
        let speaker = MeetingSpeaker(label: "A", track: "system", providerName: "RunPod")
        meeting.speakers = [speaker]
        meeting.transcript = [.init(speaker: "A", text: "Original", speakerID: speaker.id)]
        try store.insertImportedMeeting(meeting)
        var attempt = ProviderTranscriptionAttempt(provider: provider(), meeting: meeting)
        let replacement = SpeakerRecognition.result(
            [.init(start: 0, end: 2, text: "Replacement", speaker: "B", track: "system", embedding: [1, 0])],
            attempt: attempt, people: store.people)
        attempt.result = replacement.segments
        attempt.resultSpeakers = replacement.speakers
        try store.saveTranscriptionAttempt(attempt, meetingID: meeting.id)
        store.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: person)
        #expect(throws: (any Error).self) {
            try store.saveTranscriptionResult(replacement.segments, attempt: attempt, meetingID: meeting.id)
        }
        #expect(store.meetings[0].transcript[0].text == "Original")
        let reopened = MeetingStore(dataDirectory: root)
        _ = try #require(reopened.meeting(id: meeting.id))
        reopened.applySavedTranscriptionResult(meetingID: meeting.id)
        #expect(reopened.meetings[0].transcript[0].text == "Replacement")
        #expect(reopened.meetings[0].speakers == replacement.speakers)
        #expect(reopened.meetings[0].personIDs.isEmpty)
    }

    @Test func exportsResolveNamesAndExcludeVoiceDataAndPersonDeletionClearsLinks() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let person = store.addPerson(name: "Alex")
        var meeting = Meeting()
        let speaker = MeetingSpeaker(
            label: "raw_label", track: "system", providerName: "RunPod",
            voiceScope: "runpod:test", embedding: [1, 0])
        meeting.speakers = [speaker]
        meeting.transcript = [.init(speaker: speaker.label, text: "Hello", speakerID: speaker.id)]
        try store.insertImportedMeeting(meeting)
        store.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: person)
        let json = root.appendingPathComponent("export.json")
        try store.exportMeeting(id: meeting.id, to: json)
        let exported = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: json))
        #expect(exported.speakers.isEmpty)
        #expect(exported.transcript[0].speaker == "Alex")
        #expect(exported.transcript[0].speakerID == nil)
        let markdown = root.appendingPathComponent("export.md")
        try store.exportMeeting(id: meeting.id, to: markdown)
        #expect(try String(contentsOf: markdown, encoding: .utf8).contains("**Alex:** Hello"))
        store.deletePerson(id: person)
        #expect(store.meetings[0].speakers[0].personID == nil)
        #expect(!store.meetings[0].speakers[0].confirmed)
        #expect(store.meetings[0].personIDs.isEmpty)
    }

    @Test func importingTextRestoresLabelsAndNeverReusesForeignPersonLinks() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let person = store.addPerson(name: "Local Person")
        let speaker = MeetingSpeaker(
            label: "SPEAKER_00", track: "system", providerName: "RunPod",
            personID: person, confidence: 1, confirmed: true)
        var archive = Meeting()
        archive.speakers = [speaker]
        archive.personIDs = [person]
        archive.transcript = [.init(speaker: speaker.label, text: "Hello", speakerID: speaker.id)]
        let file = root.appendingPathComponent("input.json")
        try JSONEncoder().encode(archive).write(to: file)
        try store.importArchive(url: file)
        #expect(store.meetings[0].speakers[0].personID == nil)
        #expect(!store.meetings[0].speakers[0].confirmed)
        #expect(store.meetings[0].personIDs.isEmpty)
        archive.speakers = []
        archive.transcript[0].speakerID = UUID()
        try JSONEncoder().encode(archive).write(to: file)
        try store.importArchive(url: file)
        #expect(store.meetings[0].speakers.count == 1)
        #expect(store.meetings[0].speakers[0].id == store.meetings[0].transcript[0].speakerID)
        #expect(store.meetings[0].speakers[0].embedding == nil)
    }

    @Test func failedAssignmentSaveRollsBackVoiceSampleAndPersonLinkTogether() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let person = store.addPerson(name: "Alex")
        let speaker = MeetingSpeaker(
            label: "SPEAKER_00", track: "system", providerName: "RunPod",
            voiceScope: "runpod:test", embedding: [1, 0])
        var meeting = Meeting()
        meeting.speakers = [speaker]
        try store.insertImportedMeeting(meeting)
        let file = store.directory(for: meeting.id).appendingPathComponent("metadata.json")
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("before.json"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        store.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: person)
        #expect(store.errorMessage != nil)
        #expect(store.people[0].voiceSamples.isEmpty)
        #expect(store.meetings[0].speakers[0].personID == nil)
        #expect(store.meetings[0].personIDs.isEmpty)
    }

    @Test func oldSavedResultRestoresSpeakerIdentitiesOnBothApplyPaths() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let result = [TranscriptSegment(speaker: "Legacy Speaker", text: "Retained result")]
        for explicit in [false, true] {
            var meeting = Meeting(title: "Old pending result")
            var attempt = ProviderTranscriptionAttempt(provider: provider(), meeting: meeting)
            attempt.originalSpeakers = nil
            attempt.resultSpeakers = nil
            attempt.result = result
            meeting.transcriptionAttempt = attempt
            try store.insertImportedMeeting(meeting)
            if explicit {
                store.applySavedTranscriptionResult(meetingID: meeting.id)
            }
            else {
                try store.saveTranscriptionResult(result, attempt: attempt, meetingID: meeting.id)
            }
            let saved = try #require(store.meetings.first { $0.id == meeting.id })
            #expect(saved.speakers.count == 1)
            #expect(saved.speakers[0].id == saved.transcript[0].speakerID)
            #expect(saved.speakers[0].personID == nil)
            #expect(saved.speakers[0].embedding == nil)
        }
    }

    @Test func removingAssignmentRemovesSpeakerPersonAssociation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let person = store.addPerson(name: "Alex")
        var meeting = Meeting()
        let match = MeetingSpeaker(label: "A", track: "system", providerName: "RunPod", personID: person)
        meeting.personIDs = [person]
        meeting.speakers = [match]
        try store.insertImportedMeeting(meeting)
        store.assignSpeaker(meetingID: meeting.id, speakerID: match.id, personID: nil)
        #expect(store.meetings[0].personIDs.isEmpty)
        #expect(store.meetings[0].speakers[0].personID == nil)
        meeting.replaceSpeakers([])
        #expect(meeting.personIDs.isEmpty)
    }

    @Test func voiceDataHasNoOutboundPrivacyRoute() {
        var settings = AppSettings()
        settings.serviceProviders = [provider()]
        settings.transcriptionProviderID = settings.serviceProviders[0].id
        let row = DataPrivacy.rows(.init(settings: settings)).first { $0.type == .voiceSamples }
        #expect(row?.sendsToProvider == false)
        #expect(row?.type.contents?.contains("Recognition runs on this Mac") == true)
    }
}
