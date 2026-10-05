import Combine
import Foundation

struct TranscriptHistoryReadKey: Equatable, Sendable {
    var directory: URL
    var meetingID: UUID
    var source: TranscriptSource?
    var labelingSource: SpeakerLabelSource?
}

struct TranscriptHistorySnapshot: Sendable {
    var draft: LiveTranscriptDraft?
    var revisions: [TranscriptRevision] = []
    var failure: String?

    static func read(_ key: TranscriptHistoryReadKey) -> Self {
        var result = Self()
        do {
            let folder = try MeetingFolderLocation.resolve(id: key.meetingID, directory: key.directory)
            result.draft = try LiveTranscriptDraft.read(at: folder, meetingID: key.meetingID)
            result.revisions = try TranscriptRevisions.read(at: folder).revisions
        }
        catch { result.failure = error.localizedDescription }
        return result
    }
}

/// Requests may finish out of order; only the latest snapshot can reach the view.
@MainActor final class TranscriptHistoryReader: ObservableObject {
    private var request = UUID()
    private let read: @Sendable (TranscriptHistoryReadKey) async -> TranscriptHistorySnapshot

    init(
        read: @escaping @Sendable (TranscriptHistoryReadKey) async -> TranscriptHistorySnapshot = { key in
            await Task.detached(priority: .userInitiated) { TranscriptHistorySnapshot.read(key) }.value
        }
    ) {
        self.read = read
    }

    func load(_ key: TranscriptHistoryReadKey) async -> TranscriptHistorySnapshot? {
        let token = UUID()
        request = token
        let result = await read(key)
        guard request == token, !Task.isCancelled else { return nil }
        return result
    }
}
