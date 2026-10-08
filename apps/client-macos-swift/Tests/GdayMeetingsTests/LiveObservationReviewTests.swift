import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct LiveObservationReviewTests {
    private func example(meeting: UUID, speaker: UUID, observation: String, start: Double = 0) -> VoiceExample {
        let type = EmbeddingType(
            modelID: "fixture", revision: "1", compatibilityVersion: "1",
            dimension: 2, normalization: "unitL2")
        return .init(
            id: MeetingSpeakerConsolidation.identity(
                meetingID: meeting, clusterID: observation,
                method: "live-observation-evidence-v1"),
            meetingID: meeting, speakerID: speaker, source: "microphone", audioFile: "microphone.wav",
            start: start, end: start + 3, embeddings: [.init(type: type, values: [1, 0])],
            groupID: speaker, origin: .liveSpeech, observationID: observation)
    }

    @Test func revisedClusterMovesUnreviewedSampleWithoutDuplicatingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceLibraryStore(loading: .immediate, directory: root)
        let meeting = UUID()
        let first = UUID()
        let second = UUID()
        let original = example(meeting: meeting, speaker: first, observation: "same-audio")
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: [original]))
        let moved = example(meeting: meeting, speaker: second, observation: "same-audio")
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: [moved]))
        #expect(store.examples.count == 1)
        #expect(store.examples.first?.id == original.id)
        #expect(store.examples.first?.speakerID == second)
        #expect(store.examples.first?.groupID == second)
        #expect(store.examples.first?.personID == nil)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(reopened.examples == store.examples)
        #expect(reopened.hydratedExample(id: original.id)?.embeddings == original.embeddings)
    }

    @Test func changingRepresentativesPreservesReviewsAndUnrelatedMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceLibraryStore(loading: .immediate, directory: root)
        let meeting = UUID()
        let speaker = UUID()
        let person = UUID()
        let reviewed = example(meeting: meeting, speaker: speaker, observation: "reviewed")
        let obsolete = example(meeting: meeting, speaker: speaker, observation: "obsolete", start: 4)
        let other = example(meeting: UUID(), speaker: UUID(), observation: "unrelated")
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: [reviewed, obsolete]))
        #expect(store.upsert([other]))
        #expect(store.confirm(ids: [reviewed.id], personID: person))
        let replacement = example(meeting: meeting, speaker: UUID(), observation: "better", start: 10)
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: [replacement]))
        #expect(Set(store.examples.map(\.id)) == Set([reviewed.id, replacement.id, other.id]))
        #expect(store.examples.first { $0.id == reviewed.id }?.personID == person)
        #expect(store.examples.first { $0.id == reviewed.id }?.review == .confirmed)
        var retargeted = reviewed
        retargeted.speakerID = replacement.speakerID
        retargeted.groupID = replacement.groupID
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: [retargeted, replacement]))
        #expect(store.examples.first { $0.id == reviewed.id }?.speakerID == speaker)
        #expect(store.examples.first { $0.id == reviewed.id }?.personID == person)
    }

    @Test func rejectionCannotBeErasedAndChangedAudioIdentityIsRejectedAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceLibraryStore(loading: .immediate, directory: root)
        let meeting = UUID()
        let speaker = UUID()
        let value = example(meeting: meeting, speaker: speaker, observation: "rejected")
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: [value]))
        #expect(store.assign(meetingID: meeting, speakerID: speaker, personID: nil, exampleID: value.id))
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: []))
        #expect(store.examples.first?.review == .rejected)
        let before = store.examples
        var corrupt = value
        corrupt.end = 8
        #expect(!store.reconcileObservationExamples(meetingID: meeting, representatives: [corrupt]))
        #expect(store.examples == before)
    }
    @Test func sharedMeetingVoiceProjectsReviewOnlyOntoCorrectSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Two sources, one anonymous voice")
        let folder = try MeetingFolderLocation.newFolder(id: meeting.id, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["microphone.wav", "system.wav"] {
            try Data("fixture".utf8).write(to: folder.appendingPathComponent(file))
        }
        meeting.audioFiles = ["microphone.wav", "system.wav"]
        let speaker = MeetingSpeaker(label: "Speaker 1", track: "multiple", providerName: "Fixture")
        meeting.replaceSpeakers([speaker])
        meeting.transcript = [
            .init(
                start: 0, end: 3, speaker: speaker.label, text: "Microphone", speakerID: speaker.id,
                source: .microphone),
            .init(
                start: 0, end: 3, speaker: speaker.label, text: "System", speakerID: speaker.id,
                source: .system),
        ]
        var reviewed = example(meeting: meeting.id, speaker: speaker.id, observation: "mic-only")
        reviewed.audioRevision = VoiceLibraryStore.revision(url: folder.appendingPathComponent("microphone.wav"))
        let store = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(store.reconcileObservationExamples(meetingID: meeting.id, representatives: [reviewed]))
        let person = UUID()
        #expect(store.confirm(ids: [reviewed.id], personID: person))
        let projected = store.applyingDecisions(to: meeting)
        let microphoneID = try #require(projected.transcript[0].speakerID)
        let systemID = try #require(projected.transcript[1].speakerID)
        #expect(projected.speakers.first { $0.id == microphoneID }?.personID == person)
        #expect(projected.speakers.first { $0.id == systemID }?.personID == nil)
        #expect(microphoneID != systemID)
        var bounded = meeting
        bounded.speakers[0].manuallyAssigned = true
        bounded.speakers[0].manualReviewThrough = ["microphone": 0, "system": 0]
        let exactReview = store.applyingDecisions(to: bounded)
        let exact = try #require(exactReview.speakers.first { $0.id == exactReview.transcript[0].speakerID })
        #expect(exact.protectsManualAssignment(to: exactReview.transcript[0]))
        #expect(exact.voiceReviewOrigin?.manualReviewThrough == bounded.speakers[0].manualReviewThrough)
        #expect(store.undo())
        let restored = store.applyingDecisions(to: exactReview)
        #expect(
            restored.speakers.first { $0.id == speaker.id }?.manualReviewThrough
                == bounded.speakers[0].manualReviewThrough)
    }

    @Test func finalizedAudioKeepsReviewedRetiredClusterPlayable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Finalized recording")
        let folder = try MeetingFolderLocation.newFolder(id: meeting.id, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("final audio".utf8).write(to: folder.appendingPathComponent("microphone.m4a"))
        meeting.audioFiles = ["microphone.m4a"]
        let retired = example(meeting: meeting.id, speaker: UUID(), observation: "reviewed-retired")
        let store = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(store.reconcileObservationExamples(meetingID: meeting.id, representatives: [retired]))
        let person = UUID()
        #expect(store.confirm(ids: [retired.id], personID: person))
        #expect(store.ingest(meeting: meeting, directory: folder, finalizeLive: true))
        let finalized = try #require(store.examples.first { $0.id == retired.id })
        #expect(finalized.audioFile == "microphone.m4a")
        #expect(finalized.personID == person)
        #expect(finalized.review == .confirmed)
        #expect(store.audioIsCurrent(finalized))
    }

    @Test func selectionRotationKeepsEvidenceNeededByUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceLibraryStore(loading: .immediate, directory: root)
        let meeting = UUID()
        let value = example(meeting: meeting, speaker: UUID(), observation: "undo-evidence")
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: [value]))
        #expect(store.exclude(ids: [value.id]))
        #expect(store.exclude(ids: [value.id], excluded: false))
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: []))
        #expect(store.examples.contains { $0.id == value.id })
        #expect(store.undo())
        #expect(store.examples.first { $0.id == value.id }?.excluded == true)
    }

    @Test func savedAudioRelabelingUsesRowSourceAndLiveReviewBoundary() {
        let named = MeetingSpeaker(
            label: "Speaker 1", track: "multiple", providerName: "Live", personID: UUID(),
            manuallyAssigned: true, manualReviewThrough: ["microphone": 10, "system": 10])
        let corrected = MeetingSpeaker(label: "Speaker 2", track: "track1", providerName: "Saved Audio")
        var meeting = Meeting(title: "Shared voice, later new speaker")
        meeting.replaceSpeakers([named])
        meeting.transcript = [
            .init(start: 1, end: 4, speaker: named.label, text: "Reviewed", speakerID: named.id, source: .system),
            .init(start: 12, end: 15, speaker: named.label, text: "New speaker", speakerID: named.id, source: .system),
        ]
        let result = LocalDiarizationResult(
            modelRevision: "fixture",
            ranges: [.init(track: "track1", label: corrected.label, start: 0, end: 20)],
            speakers: [corrected], trackSources: ["track0": "microphone", "track1": "system"])
        let updated = LocalDiarizationAssignment.applying(result, to: meeting, fileCount: 2)
        #expect(updated.transcript[0] == meeting.transcript[0])
        #expect(updated.transcript[1].speakerID == corrected.id)
    }

    @Test func backgroundPreparationRebasesOnConcurrentHumanReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceLibraryStore(loading: .immediate, directory: root)
        let meeting = UUID()
        let value = example(meeting: meeting, speaker: UUID(), observation: "concurrent-review")
        #expect(store.reconcileObservationExamples(meetingID: meeting, representatives: [value]))
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        store.beforeObservationPreparation = {
            entered.continuation.yield(())
            release.wait()
        }
        var moved = value
        moved.speakerID = UUID()
        let reconciliation = Task {
            await store.reconcileObservationExamplesForCapture(meetingID: meeting, representatives: [moved])
        }
        for await _ in entered.stream { break }
        let person = UUID()
        #expect(store.confirm(ids: [value.id], personID: person))
        store.beforeObservationPreparation = nil
        release.signal()
        #expect(await reconciliation.value)
        let reviewed = try #require(store.examples.first { $0.id == value.id })
        #expect(reviewed.personID == person && reviewed.review == .confirmed)
        #expect(reviewed.speakerID == value.speakerID)
    }

}
