import Combine
import Foundation
import Testing

@testable import GdayMeetings

@MainActor
@Suite(.serialized)
struct VoiceReviewObservationTests {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func unrelatedProgressPublicationsKeepSnapshotUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let playback = MeetingPlayback()
        let observation = VoiceReviewObservation(store: store, library: store.voiceLibrary, playback: playback)
        await drainMainQueue()
        let initial = observation.snapshot
        var publications = 0
        let subscription = observation.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        store.isLoadingMeetingPage = true
        store.isLoadingMeetingPage = false
        store.errorMessage = "Synthetic background task error"
        playback.objectWillChange.send()
        store.voiceLibrary.objectWillChange.send()
        await drainMainQueue()
        #expect(observation.snapshot == initial)
        #expect(publications == 0)
    }

    @Test func relatedChangesCoalesceAndIncludeLatestValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let observation = VoiceReviewObservation(store: store, library: store.voiceLibrary, playback: MeetingPlayback())
        await drainMainQueue()
        var publications = 0
        let subscription = observation.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let revision = UUID()
        let person = Person(name: "Sample Person")
        store.people = [person]
        store.directoryRevision = revision
        #expect(observation.snapshot.people.isEmpty)
        await drainMainQueue()
        #expect(observation.snapshot.people == [person])
        #expect(observation.snapshot.directoryRevision == revision)
        #expect(publications == 1)
    }

    @Test func recordingLabelRevisionPublishesWithoutDirectoryChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let observation = VoiceReviewObservation(store: store, library: store.voiceLibrary, playback: MeetingPlayback())
        await drainMainQueue()
        let originalDirectory = observation.snapshot.directoryRevision
        let revision = UUID()
        store.meetingIndexRevision = revision
        await drainMainQueue()
        #expect(observation.snapshot.meetingIndexRevision == revision)
        #expect(observation.snapshot.directoryRevision == originalDirectory)
    }

    @Test func playbackBlockingPublishesLatestState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let playback = MeetingPlayback()
        let observation = VoiceReviewObservation(store: store, library: store.voiceLibrary, playback: playback)
        await drainMainQueue()
        playback.setRecordingActive(true)
        await drainMainQueue()
        #expect(observation.snapshot.playbackBlocked)
        playback.setRecordingActive(false)
        await drainMainQueue()
        #expect(!observation.snapshot.playbackBlocked)
    }

    @Test func metadataAndUndoChangesPublishTheirRevisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let library = store.voiceLibrary
        let observation = VoiceReviewObservation(store: store, library: library, playback: MeetingPlayback())
        let initial = observation.snapshot
        let example = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        #expect(library.upsert([example]))
        await drainMainQueue()
        #expect(observation.snapshot.reviewMetadataRevision > initial.reviewMetadataRevision)
        #expect(library.confirm(ids: [example.id], personID: UUID()))
        await drainMainQueue()
        #expect(observation.snapshot.canUndo)
        #expect(observation.snapshot.reviewUndoID == library.reviewUndoID)
        #expect(observation.snapshot.reviewUndoID != nil)
        #expect(observation.snapshot.reviewEvidenceRevision > initial.reviewEvidenceRevision)
        #expect(library.undo())
        await drainMainQueue()
        #expect(observation.snapshot.canUndo == library.canUndo)
        #expect(observation.snapshot.reviewUndoID == library.reviewUndoID)
    }

    @Test func pendingRefreshDoesNotRetainObservation() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let playback = MeetingPlayback()
        var observation: VoiceReviewObservation? = VoiceReviewObservation(
            store: store, library: store.voiceLibrary, playback: playback)
        weak let released = observation
        store.objectWillChange.send()
        observation = nil
        #expect(released == nil)
        await drainMainQueue()
        #expect(released == nil)
    }
}

extension VoiceReviewObservationTests {
    @Test func recordingAndFinalizationPublishBusyStateWithoutPlaybackChanges() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let observation = VoiceReviewObservation(store: store, library: store.voiceLibrary, playback: MeetingPlayback())
        await drainMainQueue()
        #expect(!observation.snapshot.recordingBusy && !observation.snapshot.playbackBlocked)
        store.isFinalizingRecording = true
        await drainMainQueue()
        #expect(observation.snapshot.recordingBusy && !observation.snapshot.playbackBlocked)
        store.isFinalizingRecording = false
        store.recordingID = UUID()
        await drainMainQueue()
        #expect(observation.snapshot.recordingBusy)
        store.recordingID = nil
        await drainMainQueue()
        #expect(!observation.snapshot.recordingBusy)
    }
}
