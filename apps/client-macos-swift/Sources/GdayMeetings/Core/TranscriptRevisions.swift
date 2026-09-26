import Foundation

struct TranscriptRevision: Codable, Identifiable, Equatable {
    var id = UUID()
    var savedAt = Date()
    var title: String
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
    static func preserve(_ meeting: Meeting, at directory: URL, title: String = "Previous Transcript") throws {
        guard !meeting.transcript.isEmpty else { return }
        var value = try read(at: directory)
        if let last = value.revisions.last, last.segments == meeting.transcript, last.speakers == meeting.speakers {
            return
        }
        value.revisions.append(
            TranscriptRevision(title: title, segments: meeting.transcript, speakers: meeting.speakers))
        try PrivateTranscriptFile.write(
            try JSONEncoder().encode(value), name: "transcript-revisions.json", at: directory)
    }
}

enum PrivateTranscriptFile {
    static func write(_ data: Data, name: String, at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let target = directory.appendingPathComponent(name)
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
        guard var meeting = meetings.first(where: { $0.id == meetingID }), preserveTranscript(meeting) else { return }
        meeting.transcript = revision.segments
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
