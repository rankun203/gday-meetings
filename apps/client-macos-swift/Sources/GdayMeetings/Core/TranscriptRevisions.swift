import Foundation

struct TranscriptSource: Codable, Equatable {
    var id: UUID
    var providerName: String
    var generatedAt: Date
}

struct TranscriptRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    var savedAt = Date()
    var title: String
    var source: TranscriptSource? = nil
    var segments: [TranscriptSegment]
    var speakers: [MeetingSpeaker]
}
struct TranscriptRevisions: Codable {
    var version = 1
    var revisions: [TranscriptRevision] = []
    static func read(at directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("transcript-revisions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.version == 1 else {
            throw MeetingError.message("The saved transcript revisions use an unsupported format.")
        }
        return result
    }
    static func preserve(_ meeting: Meeting, at directory: URL) throws {
        guard !meeting.transcript.isEmpty else { return }
        var value = try read(at: directory)
        let revision = current(meeting)
        if let index = value.revisions.firstIndex(where: { $0.id == revision.id }) {
            guard value.revisions[index] != revision else { return }
            value.revisions[index] = revision
        }
        else {
            value.revisions.append(revision)
        }
        try PrivateTranscriptFile.write(
            try JSONEncoder().encode(value), name: "transcript-revisions.json", at: directory)
    }
    static func current(_ meeting: Meeting) -> TranscriptRevision {
        TranscriptRevision(
            id: meeting.transcriptSource?.id ?? meeting.id,
            savedAt: meeting.transcriptSource?.generatedAt ?? meeting.createdAt,
            title: meeting.transcriptSource?.providerName ?? "Transcript", source: meeting.transcriptSource,
            segments: meeting.transcript, speakers: meeting.speakers)
    }
    static func choices(_ revisions: [TranscriptRevision], current meeting: Meeting) -> [TranscriptRevision] {
        var values = revisions.filter { $0.id != (meeting.transcriptSource?.id ?? meeting.id) }
        if !meeting.transcript.isEmpty { values.append(current(meeting)) }
        return values.sorted { $0.savedAt > $1.savedAt }
    }

}

enum PrivateTranscriptFile {
    static func write(_ data: Data, name: String, at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let target = directory.appendingPathComponent(name)
        let previous = try? Data(contentsOf: target)
        let temporary = directory.appendingPathComponent(".transcript-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: data,
                attributes: [.posixPermissions: 0o600])
        else {
            throw MeetingError.message("Couldn’t save the transcript revision.")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary, options: .usingNewMetadataOnly)
        }
        else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        DataEventJournal.recordSavedFile(target, previous: previous, directory: directory)
    }
}

extension MeetingStore {
    func preserveTranscript(_ meeting: Meeting) -> Bool {
        guard libraryWritable else { return false }
        do {
            try TranscriptRevisions.preserve(meeting, at: directory(for: meeting.id))
            return true
        }
        catch {
            errorMessage = "Couldn’t save the previous transcript. The current transcript was kept."
            return false
        }
    }
    func restoreTranscript(_ revision: TranscriptRevision, meetingID: UUID) {
        guard var meeting = self.meeting(id: meetingID), preserveTranscript(meeting) else { return }
        meeting.transcript = revision.segments
        meeting.transcriptSource =
            revision.source
            ?? TranscriptSource(
                id: revision.id, providerName: "Transcript", generatedAt: revision.savedAt)
        // A deleted person must not be recreated by restoring a transcript.
        meeting.replaceSpeakers(
            revision.speakers.map { speaker in
                var speaker = speaker
                if let id = speaker.personID, !people.contains(where: { $0.id == id }) {
                    speaker.personID = nil
                    speaker.confirmed = false
                    speaker.confidence = nil
                }
                return speaker
            })
        updateMeeting(meeting)
    }
}
