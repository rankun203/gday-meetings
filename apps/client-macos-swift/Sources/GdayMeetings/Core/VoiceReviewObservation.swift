import Combine
import Foundation

/// Review content observes only values that can change its evidence or actions.
/// Transport progress and unrelated library work keep their own observers.
@MainActor
final class VoiceReviewObservation: ObservableObject {
    struct Snapshot: Equatable {
        let people: [Person]
        let policy: VoiceMatchingPolicy
        let libraryWritable: Bool
        let canUndo: Bool
        let reviewUndoID: UUID?
        let reviewEvidenceRevision: Int
        let reviewMetadataRevision: Int
        let directoryRevision: UUID
        let meetingIndexRevision: UUID
        let playbackBlocked: Bool
        let recordingBusy: Bool
        let playbackError: String?
    }

    let store: MeetingStore
    let library: VoiceLibraryStore
    let playback: MeetingPlayback
    @Published private(set) var snapshot: Snapshot
    private var subscriptions: [AnyCancellable] = []
    private var pendingRefresh: DispatchWorkItem?

    init(store: MeetingStore, library: VoiceLibraryStore, playback: MeetingPlayback) {
        self.store = store
        self.library = library
        self.playback = playback
        snapshot = Self.capture(store: store, library: library, playback: playback)
        subscriptions = [
            store.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() },
            library.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() },
            playback.$isPlaybackBlocked.removeDuplicates().sink { [weak self] _ in self?.scheduleRefresh() },
            playback.$errorMessage.removeDuplicates().sink { [weak self] _ in self?.scheduleRefresh() },
        ]
    }

    deinit {
        pendingRefresh?.cancel()
        subscriptions.forEach { $0.cancel() }
    }

    private func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        // Published values send before mutation. Read the completed transaction
        // on the next main queue turn, folding its related publications together.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            let next = Self.capture(store: self.store, library: self.library, playback: self.playback)
            if next != self.snapshot { self.snapshot = next }
        }
        pendingRefresh = work
        DispatchQueue.main.async(execute: work)
    }

    private static func capture(store: MeetingStore, library: VoiceLibraryStore, playback: MeetingPlayback) -> Snapshot
    {
        Snapshot(
            people: store.people,
            policy: store.settings.serviceProviders.first { $0.id == store.settings.diarizationProviderID }?
                .voiceMatchingPolicy ?? .default, libraryWritable: store.libraryWritable,
            canUndo: library.canUndo, reviewUndoID: library.reviewUndoID,
            reviewEvidenceRevision: library.reviewEvidenceRevision,
            reviewMetadataRevision: library.reviewMetadataRevision,
            directoryRevision: store.directoryRevision, meetingIndexRevision: store.meetingIndexRevision,
            playbackBlocked: playback.isPlaybackBlocked,
            recordingBusy: store.recordingID != nil || store.isStartingRecording || store.isFinalizingRecording,
            playbackError: playback.errorMessage)
    }
}
