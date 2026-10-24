import Foundation
import Testing

@testable import GdayMeetings

private actor FeedbackReferenceExtractor: VoiceExampleEmbeddingExtracting {
    var failuresRemaining: Int
    init(failures: Int = 0) { failuresRemaining = failures }
    func extract(example: VoiceExample, directory: URL, type: EmbeddingType) async throws -> TypedVoiceEmbedding {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ServiceError("Synthetic extraction failure")
        }
        return .init(type: type, values: [1] + Array(repeating: 0, count: type.dimension - 1))
    }
}

@MainActor
struct VoiceReferenceFeedbackTests {
    private struct Fixture {
        var root: URL
        var store: MeetingStore
        var meeting: Meeting
        var speaker: MeetingSpeaker
        var personID: UUID
        var folder: URL
        var example: VoiceExample
    }

    private func fixture(scanned: Bool, withAudio: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let personID = await store.addPerson(name: "Person A")
        let range = VoiceSampleRange(audioFile: "system.wav", source: "system", start: 0, end: 4)
        let speaker = MeetingSpeaker(
            label: "voice_a", track: "system", providerName: "Synthetic", personID: personID,
            voiceSampleRange: range, manuallyAssigned: true)
        var meeting = Meeting(title: "Synthetic reference feedback", audioFiles: withAudio ? ["system.wav"] : [])
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 4, text: "Synthetic speech", speakerID: speaker.id, source: .system)
        ]
        let folder = store.directory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if withAudio {
            try Data("Synthetic audio revision".utf8).write(to: folder.appendingPathComponent("system.wav"))
        }
        try await store.insertImportedMeeting(meeting)
        await store.flushVoiceAssignmentRefresh()
        await store.voicePreparation.shutdown()
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        let revision = VoiceLibraryStore.revision(url: folder.appendingPathComponent("system.wav"))
        let example = VoiceExample(
            meetingID: meeting.id, speakerID: speaker.id, source: "system", audioFile: range.audioFile,
            audioRevision: revision, start: range.start, end: range.end)
        #expect(library.upsert([example]))
        #expect(
            library.assign(
                meetingID: meeting.id, speakerID: speaker.id, personID: personID, updateReferenceEvidence: false))
        if scanned, let revision {
            let analysis = LocalDiarizationResult(
                modelRevision: "synthetic", ranges: [.init(track: "system", label: speaker.label, start: 0, end: 4)],
                speakers: [speaker], trackSources: ["system": "system"])
            try await VoiceDiscoveryCache().save(
                analysis,
                input: .init(
                    meetingID: meeting.id, audioFiles: meeting.audioFiles, audioRevisions: ["system.wav": revision]),
                configuration: .community, directory: folder)
        }
        return .init(
            root: root, store: store, meeting: meeting, speaker: speaker, personID: personID, folder: folder,
            example: example)
    }

    private func prepare(_ fixture: Fixture, extractor: FeedbackReferenceExtractor = .init(), silent: Bool = false)
        async
    {
        let preparation = VoiceLibraryPreparation(
            library: fixture.store.voiceLibrary, people: { fixture.store.people }, referenceExtractor: extractor,
            referenceReadSamples: { _, range in
                .init(repeating: silent ? 0 : 0.1, count: Int(range.speechDuration * 16000))
            })
        preparation.selectReference(
            meetingID: fixture.meeting.id, speakerID: fixture.speaker.id, personID: fixture.personID,
            exampleID: fixture.example.id, directory: fixture.folder)
        await preparation.awaitReferenceSelections()
        #expect(preparation.referenceTokens.isEmpty)
    }

    @Test func oldDecisionsDecodeWithoutInventingARecognitionOutcome() throws {
        let old = """
            {"meetingID":"00000000-0000-0000-0000-000000000001","speakerID":"00000000-0000-0000-0000-000000000002","personID":"00000000-0000-0000-0000-000000000003","referenceSelectionPending":false}
            """
        let decision = try JSONDecoder().decode(VoiceSpeakerDecision.self, from: Data(old.utf8))
        #expect(decision.referenceSelectionResult == nil)
        #expect(decision.referenceSelectionID == nil)
    }

    @Test func scanNeededPersistsAndRetainsAutomaticResumeEligibility() async throws {
        let value = try await fixture(scanned: false)
        defer { try? FileManager.default.removeItem(at: value.root) }
        await prepare(value)
        let decision = try #require(value.store.voiceLibrary.decisions.first { $0.speakerID == value.speaker.id })
        #expect(decision.referenceSelectionResult?.outcome == .scanNeeded)
        #expect(decision.referenceSelectionPending == true)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: value.root)
        #expect(
            reopened.referenceDecision(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID) == decision)
    }

    @Test func absentAudioAndUnsuitableAudioHaveDifferentOutcomes() async throws {
        let absent = try await fixture(scanned: false, withAudio: false)
        defer { try? FileManager.default.removeItem(at: absent.root) }
        await prepare(absent)
        #expect(absent.store.voiceLibrary.decisions.first?.referenceSelectionResult?.outcome == .audioUnavailable)
        #expect(absent.store.voiceLibrary.decisions.first?.referenceSelectionPending == false)
        let silent = try await fixture(scanned: true)
        defer { try? FileManager.default.removeItem(at: silent.root) }
        await prepare(silent, silent: true)
        #expect(silent.store.voiceLibrary.decisions.first?.referenceSelectionResult?.outcome == .noSuitableSample)
        #expect(silent.store.voiceLibrary.examples.allSatisfy { $0.selectedReference == nil })
    }

    @Test func failureCanRetryAndOnlyAcceptedEvidenceReportsAdded() async throws {
        let value = try await fixture(scanned: true)
        defer { try? FileManager.default.removeItem(at: value.root) }
        let extractor = FeedbackReferenceExtractor(failures: 1)
        await prepare(value, extractor: extractor)
        let library = value.store.voiceLibrary
        #expect(library.decisions.first?.referenceSelectionResult?.outcome == .failed)
        #expect(library.examples.allSatisfy { $0.selectedReference == nil })
        let oldID = try #require(library.decisions.first?.referenceSelectionID)
        #expect(
            library.restartReferenceSelection(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID))
        #expect(library.decisions.first?.referenceSelectionID != oldID)
        await prepare(value, extractor: extractor)
        let result = try #require(library.decisions.first?.referenceSelectionResult)
        #expect(result.outcome == .sampleAdded)
        let accepted = try #require(result.sampleID.flatMap { library.referenceExample(id: $0) })
        #expect(accepted.review == .confirmed && accepted.personID == value.personID)
        #expect(
            try await library.referenceSampleUsage(result: result, personID: value.personID, people: value.store.people)
                == .available)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: value.root)
        #expect(reopened.decisions.first?.referenceSelectionResult == result)
        #expect(
            library.restartReferenceSelection(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID))
        await prepare(value)
        #expect(library.decisions.first?.referenceSelectionResult?.outcome == .sampleAvailable)
        #expect(library.examples.filter { $0.selectedReference != nil }.count == 1)
    }

    @Test func newerSamePersonChoiceRejectsAnOlderResult() async throws {
        let value = try await fixture(scanned: false)
        defer { try? FileManager.default.removeItem(at: value.root) }
        let library = value.store.voiceLibrary
        let first = try #require(library.decisions.first?.referenceSelectionID)
        #expect(
            library.assign(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID,
                updateReferenceEvidence: false))
        #expect(
            !library.finishReferenceSelection(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID,
                result: .init(outcome: .failed), expectedSelectionID: first))
        #expect(library.decisions.first?.referenceSelectionResult == nil)
        #expect(library.decisions.first?.referenceSelectionPending == true)
    }

    @Test func queuedRetryCannotRestartANewerSamePersonAssignment() async throws {
        let value = try await fixture(scanned: false)
        defer { try? FileManager.default.removeItem(at: value.root) }
        let library = value.store.voiceLibrary
        let expected = try #require(
            library.referenceDecision(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID))
        #expect(
            library.assign(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID,
                updateReferenceEvidence: false))
        let newer = try #require(
            library.referenceDecision(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID))
        #expect(
            await !value.store.retrySpeakerReference(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID,
                expectedDecision: expected))
        #expect(
            library.referenceDecision(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID) == newer)
    }

    @Test func savedRecognitionEvidenceSurvivesMissingPlaybackAudioButClearInvalidatesIt() async throws {
        let value = try await fixture(scanned: true)
        defer { try? FileManager.default.removeItem(at: value.root) }
        await prepare(value)
        let library = value.store.voiceLibrary
        let result = try #require(library.decisions.first?.referenceSelectionResult)
        let sampleID = try #require(result.sampleID)
        try FileManager.default.removeItem(at: value.folder.appendingPathComponent("system.wav"))
        #expect(
            try await library.referenceSampleUsage(result: result, personID: value.personID, people: value.store.people)
                == .available)
        #expect(library.clear(ids: [sampleID]))
        #expect(
            try await library.referenceSampleUsage(result: result, personID: value.personID, people: value.store.people)
                == .unavailable)
    }

    @Test func unrelatedUndoPreservesTheLaterOutcomeOfTheSameAssignment() async throws {
        let value = try await fixture(scanned: true)
        defer { try? FileManager.default.removeItem(at: value.root) }
        let library = value.store.voiceLibrary
        var unrelated = value.example
        unrelated.id = UUID()
        unrelated.meetingID = UUID()
        unrelated.speakerID = UUID()
        #expect(library.upsert([unrelated]))
        #expect(library.confirm(ids: [unrelated.id], personID: value.personID))
        await prepare(value)
        let result = try #require(
            library.referenceDecision(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID)?
                .referenceSelectionResult)
        #expect(result.outcome == .sampleAdded)
        #expect(library.undo())
        let restored = try #require(
            library.referenceDecision(
                meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID))
        #expect(restored.referenceSelectionPending == false)
        #expect(restored.referenceSelectionResult == result)
        #expect(
            try await library.referenceSampleUsage(result: result, personID: value.personID, people: value.store.people)
                == .available)
    }

    @Test func unrelatedUndoAlsoPreservesACompletedLegacySelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let speakerID = UUID()
        let personID = UUID()
        let backend = try VoiceLibraryPersistence(directory: root)
        var initial = VoiceLibraryDocument()
        initial.decisions = [
            .init(meetingID: meetingID, speakerID: speakerID, personID: personID, referenceSelectionPending: true)
        ]
        try backend.commit(previous: .init(), next: initial)
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let unrelated = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        #expect(library.upsert([unrelated]))
        #expect(library.confirm(ids: [unrelated.id], personID: personID))
        #expect(
            library.finishReferenceSelection(
                meetingID: meetingID, speakerID: speakerID, personID: personID,
                result: .init(outcome: .noSuitableSample)))
        #expect(library.undo())
        let decision = try #require(
            library.referenceDecision(meetingID: meetingID, speakerID: speakerID, personID: personID))
        #expect(decision.referenceSelectionResult?.outcome == .noSuitableSample)
        #expect(decision.referenceSelectionPending == false)
    }

    @Test func suspendedPreparationLeavesPendingWorkWithoutRunningActivity() async throws {
        let value = try await fixture(scanned: false)
        defer { try? FileManager.default.removeItem(at: value.root) }
        let preparation = VoiceLibraryPreparation(library: value.store.voiceLibrary)
        preparation.suspendForRecording()
        preparation.selectReference(
            meetingID: value.meeting.id, speakerID: value.speaker.id, personID: value.personID, exampleID: nil,
            directory: value.folder)
        #expect(preparation.referenceTokens.isEmpty)
        #expect(value.store.voiceLibrary.decisions.first?.referenceSelectionPending == true)
        #expect(value.store.voiceLibrary.decisions.first?.referenceSelectionResult == nil)
    }
}
