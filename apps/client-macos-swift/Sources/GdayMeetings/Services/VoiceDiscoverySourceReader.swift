import Foundation

/// The persistent job keeps identifiers, not a library-sized transcript snapshot.
/// Reading one source on this actor lets the review UI remain responsive.
actor VoiceDiscoverySourceReader {
    struct Snapshot {
        var meeting: Meeting
        var revisions: [String: String]
    }

    func read(meetingID: UUID, folder: URL) throws -> Snapshot {
        try Task.checkCancellation()
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        var meeting = try MeetingFolderStorage.read(id: meetingID, directory: root)
        let revisions = Dictionary(
            uniqueKeysWithValues: Set(meeting.audioFiles).compactMap { file in
                VoiceLibraryStore.revision(url: folder.appendingPathComponent(file)).map { (file, $0) }
            })
        meeting.notes = ""
        meeting.summary = ""
        meeting.chat = []
        meeting.todos = []
        for index in meeting.transcript.indices { meeting.transcript[index].text = "" }
        try Task.checkCancellation()
        return .init(meeting: meeting, revisions: revisions)
    }
}
