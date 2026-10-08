import Foundation
import Testing

@testable import GdayMeetings

struct LiveAssociationUncertaintyTests {
    private func fixture() -> (LiveSpeakerTimeline, LiveTranscriptPhrase, UUID) {
        let person = UUID()
        let generation = UUID()
        let original = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: generation, slot: 0,
            model: "synthetic", revision: "1", personID: person,
            voiceEmbedding: .init(
                type: .init(
                    modelID: "synthetic", revision: "1", compatibilityVersion: "1",
                    dimension: 2, normalization: "unitL2"), values: [1, 0]))
        var canonical = original
        canonical.id = UUID()
        var timeline = LiveSpeakerTimeline()
        timeline.speakers = [original, canonical]
        timeline.identityAliases = [original.id: canonical.id]
        timeline.cursors = [.init(source: .microphone, generation: generation, sequence: 0, end: 2, final: false)]
        timeline.intervals = [
            .init(source: .microphone, speakerID: original.id, start: 0, end: 1),
            .init(source: .microphone, speakerID: original.id, start: 1, end: 2, associationUncertain: true),
        ]
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 0, end: 2,
            text: "Known uncertain",
            words: [
                .init(text: "Known", start: 0, end: 1),
                .init(text: "uncertain", start: 1, end: 2),
            ])
        return (timeline, phrase, person)
    }

    @Test func provisionalSpanKeepsAnonymousClusterButCannotInheritPersonThroughAliasAndRecovery() throws {
        let (timeline, phrase, person) = fixture()
        let rows = timeline.attributing(phrase, bridgeUnknownWords: false)
        #expect(rows.count == 2)
        #expect(rows[0].personID == person)
        #expect(rows[1].speakerIdentity == rows[0].speakerIdentity)
        #expect(rows[1].personID == nil && rows[1].voiceEmbedding == nil)
        #expect(rows[1].associationUncertain == true)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.effectivePhrases = rows
        draft.speakerTimeline = timeline
        #expect(draft.segments.count == 2)
        #expect(draft.segments[1].personID == nil)
        #expect(draft.speakers.first?.canReviewVoice == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try draft.save(at: directory)
        let recovered = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: draft.meetingID))
        let uncertain = try #require(recovered.segments.last)
        #expect(uncertain.associationUncertain == true && uncertain.personID == nil)
        let speaker = try #require(recovered.speakers.first)
        #expect(!uncertain.allowsPersonAssociation(from: speaker))
        var meeting = Meeting()
        meeting.speakers = recovered.speakers
        let name = meeting.speakerName(for: uncertain, people: [.init(id: person, name: "Known Person")])
        #expect(name != "Known Person")
    }

    @Test func explicitPassageReviewOverridesUncertaintyAndWatermarkStopsFutureInheritance() {
        var (timeline, phrase, person) = fixture()
        timeline.speakers[0].manuallyAssigned = true
        timeline.speakers[0].manualReviewThrough = [LiveAudioSource.microphone.rawValue: 1]
        let rows = timeline.attributing(phrase, bridgeUnknownWords: false)
        #expect(rows.last?.personID == nil)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.effectivePhrases = rows
        draft.speakerTimeline = timeline
        draft.assignPerson(person, for: rows[1])
        #expect(draft.segments.last?.personID == person)
        #expect(draft.segments.last?.associationUncertain != true)
        timeline.speakers[0].manualReviewThrough = [LiveAudioSource.microphone.rawValue: 2]
        #expect(timeline.attributing(phrase, bridgeUnknownWords: false).last?.personID == person)
    }
    @Test @MainActor func exactReviewedExcerptOverridesOnlyItsOwnUncertainRowsAndUndoRestoresUncertainty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let meetingID = UUID()
        let speakerID = UUID()
        let originalPerson = Person(name: "Previous Person")
        let reviewedPerson = Person(name: "Reviewed Person")
        let folder = try MeetingFolderLocation.newFolder(id: meetingID, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("synthetic audio fixture".utf8).write(to: audio)
        let example = VoiceExample(
            meetingID: meetingID, speakerID: speakerID, source: "system", audioFile: "system.wav",
            audioRevision: VoiceLibraryStore.revision(url: audio), start: 2, end: 6,
            embeddings: [
                .init(
                    type: .init(
                        modelID: "synthetic", revision: "1", compatibilityVersion: "1",
                        dimension: 2, normalization: "unitL2"), values: [1, 0])
            ])
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        var meeting = Meeting(id: meetingID, audioFiles: ["system.wav"])
        meeting.speakers = [
            .init(
                id: speakerID, label: "Speaker 1", track: "system", providerName: "Synthetic",
                personID: originalPerson.id)
        ]
        meeting.transcript = [
            .init(
                start: 3, end: 5, speaker: "Speaker 1", text: "Reviewed excerpt", speakerID: speakerID,
                source: .system, associationUncertain: true),
            .init(
                start: 7, end: 9, speaker: "Speaker 1", text: "Unrelated excerpt", speakerID: speakerID,
                source: .system, associationUncertain: true),
        ]
        #expect(library.upsert([example]))
        #expect(library.confirm(ids: [example.id], personID: reviewedPerson.id))
        let projected = library.applyingDecisions(to: meeting)
        let people = [originalPerson, reviewedPerson]
        #expect(projected.speakerName(for: projected.transcript[0], people: people) == reviewedPerson.name)
        #expect(projected.speakerName(for: projected.transcript[1], people: people) == "Speaker 1")
        #expect(projected.transcript.allSatisfy { $0.associationUncertain == true })
        let saved = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(projected))
        #expect(saved.speakerName(for: saved.transcript[1], people: people) == "Speaker 1")
        #expect(library.undo())
        let restored = library.applyingDecisions(to: saved)
        #expect(restored.transcript == meeting.transcript)
        #expect(restored.transcript.allSatisfy { restored.speakerName(for: $0, people: people) == "Speaker 1" })
    }

}
