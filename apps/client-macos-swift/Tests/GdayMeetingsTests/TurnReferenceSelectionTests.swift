import Foundation
import Testing

@testable import GdayMeetings

private actor TurnReferenceExtractor: VoiceExampleEmbeddingExtracting {
    var ranges: [VoiceSampleRange] = []
    func extract(example: VoiceExample, directory: URL, type: EmbeddingType) async throws -> TypedVoiceEmbedding {
        if let range = example.range { ranges.append(range) }
        return .init(type: type, values: [1] + Array(repeating: 0, count: type.dimension - 1))
    }
}

@MainActor struct TurnReferenceSelectionTests {
    @Test func speakerPanelKeepsCanonicalVoiceWithoutRemovingDistinctUnbackedPassages() {
        let embedding = TypedVoiceEmbedding(
            type: .community1SpeechSpan,
            values: [1] + Array(repeating: 0, count: 255))
        let base = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic", voiceEmbedding: embedding)
        var first = base
        first.id = UUID()
        first.personID = UUID()
        first.voiceReviewOrigin = .init(speakerID: base.id, transcriptAssociationTier: .automatic)
        var second = first
        second.id = UUID()
        second.personID = UUID()
        var meeting = Meeting()
        meeting.speakers = [base, first, second]
        #expect(meeting.assignableSpeakers.map(\.id) == [base.id])
        meeting.speakers.removeFirst()
        #expect(meeting.assignableSpeakers.map(\.id) == [first.id, second.id])
        first.passageAssignmentOrigin = .init(speaker: "A")
        meeting.speakers = [base, first, second]
        #expect(meeting.assignableSpeakers.map(\.id) == [base.id, first.id])
    }

    @Test func directUnrecognizedClusterAssignmentAndUndoRestoreEmptyIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Person A")
        let speaker = MeetingSpeaker(
            label: "A", track: "system", providerName: "Synthetic",
            independentTurnAttribution: true)
        var meeting = Meeting(title: "Synthetic unrecognized voice")
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(
                start: 0, end: 1, text: "Short reply", speakerID: speaker.id,
                source: .system, associationUncertain: true)
        ]
        try await store.insertImportedMeeting(meeting)
        await store.flushVoiceAssignmentRefresh()
        store.voiceLibrary.didChange = nil
        store.voiceLibrary.didChangeProjection = nil
        #expect(await store.assignSpeaker(meetingID: meeting.id, speakerID: speaker.id, personID: person))
        await store.voicePreparation.awaitReferenceSelections()
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        let assigned = try #require(store.meeting(id: meeting.id))
        #expect(assigned.speakers.first { $0.id == speaker.id }?.personID == person)
        #expect(store.voiceLibrary.undo())
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        let restored = try #require(store.meeting(id: meeting.id))
        #expect(restored.speakers.first { $0.id == speaker.id }?.personID == nil)
        #expect(restored.speakers.first { $0.id == speaker.id }?.manuallyAssigned != true)
        #expect(restored.transcript == meeting.transcript)
        #expect(restored.associatedPersonIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func correctingTurnSelectsItsOwnReferenceBeforeLongerClusterTurn(discovery: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let firstPerson = await store.addPerson(name: "Person A")
        let secondPerson = await store.addPerson(name: "Person B")
        var meeting = Meeting(title: "Synthetic turn correction", audioFiles: ["system.wav"])
        let folder = store.directory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic audio revision".utf8).write(to: folder.appendingPathComponent("system.wav"))
        let revision = try #require(VoiceLibraryStore.revision(url: folder.appendingPathComponent("system.wav")))
        let sample = VoiceSampleRange(audioFile: "system.wav", source: "system", start: 0, end: 3)
        let speaker = MeetingSpeaker(
            label: "voice_a", track: "track0", providerName: "Synthetic",
            voiceSampleRange: sample, independentTurnAttribution: true)
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 3, text: "First turn", speakerID: speaker.id, source: .system),
            .init(start: 5, end: 10, text: "Longer turn", speakerID: speaker.id, source: .system),
        ]
        try await store.insertImportedMeeting(meeting)
        await store.flushVoiceAssignmentRefresh()
        let analysis = LocalDiarizationResult(
            modelRevision: "synthetic",
            ranges: [
                .init(track: "track0", label: speaker.label, start: 0, end: 3),
                .init(track: "track0", label: speaker.label, start: 5, end: 10),
            ], speakers: [speaker], trackSources: ["track0": "system"])
        let input = VoiceDiscoveryInput(
            meetingID: meeting.id, audioFiles: meeting.audioFiles,
            audioRevisions: ["system.wav": revision])
        try await VoiceDiscoveryCache().save(analysis, input: input, configuration: .community, directory: folder)
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        var first = VoiceExample(
            meetingID: meeting.id, speakerID: speaker.id, source: "system", audioFile: "system.wav",
            audioRevision: revision, start: 0, end: 3, attributionTurn: .init(start: 0, end: 3))
        first.transcriptAssociation = .init(personID: firstPerson, score: 0.9, margin: 0.3, policy: .default)
        var second = first
        second.id = UUID()
        second.start = 5
        second.end = 10
        second.attributionTurn = .init(start: 5, end: 10)
        second.transcriptAssociation?.personID = secondPerson
        if discovery {
            let discoveredSpeaker = UUID()
            first.speakerID = discoveredSpeaker
            second.speakerID = discoveredSpeaker
            first.origin = .discovery
            second.origin = .discovery
            first.detectedSpeakerConfiguration = .community
            second.detectedSpeakerConfiguration = .community
        }
        #expect(library.upsert([first, second]))
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        let projected = try #require(store.meeting(id: meeting.id))
        let selected = try #require(projected.transcript[0].speakerID)
        await store.voicePreparation.shutdown()
        let extractor = TurnReferenceExtractor()
        store.voicePreparation = VoiceLibraryPreparation(
            library: library, people: { store.people }, referenceExtractor: extractor,
            referenceReadSamples: { _, range in .init(repeating: 0.1, count: Int(range.speechDuration * 16000)) })
        #expect(await store.assignSpeaker(meetingID: meeting.id, speakerID: selected, personID: secondPerson))
        await store.voicePreparation.awaitReferenceSelections()
        let accepted = try #require(library.examples.first { $0.selectedReference != nil })
        #expect(accepted.personID == secondPerson)
        #expect(accepted.range == sample)
        #expect(await extractor.ranges == [sample])
        #expect(library.examples.first { $0.id == first.id }?.transcriptAssociation == nil)
        #expect(library.examples.first { $0.id == second.id }?.review != .confirmed)
    }
}
