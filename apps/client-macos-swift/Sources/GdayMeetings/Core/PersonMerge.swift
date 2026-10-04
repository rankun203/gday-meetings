import Foundation

struct PersonMerge {
    let sourceIDs: Set<UUID>
    let targetID: UUID

    init(sourceID: UUID, targetID: UUID) {
        self.init(sourceIDs: [sourceID], targetID: targetID)
    }

    init(sourceIDs: Set<UUID>, targetID: UUID) {
        self.sourceIDs = sourceIDs
        self.targetID = targetID
    }

    func replacing(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.map { sourceIDs.contains($0) ? targetID : $0 }.filter { seen.insert($0).inserted }
    }

    static func combining(_ source: Person, into target: Person) -> Person {
        var result = target
        var notes = [target.notes, source.notes].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if target.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.email = source.email
        }
        else if !source.email.isEmpty && source.email != target.email {
            notes.append("Additional email: \(source.email)")
        }
        if source.name != target.name { notes.append("Also known as: \(source.name)") }
        var seen = Set<String>()
        result.notes = notes.filter { seen.insert($0).inserted }.joined(separator: "\n\n")
        result.tagIDs += source.tagIDs.filter { !result.tagIDs.contains($0) }
        for sample in source.voiceSamples where !result.voiceSamples.contains(sample) {
            result.voiceSamples.append(sample)
        }
        return result
    }

    func apply(to meeting: inout Meeting) {
        meeting.personIDs = replacing(meeting.personIDs)
        for index in meeting.speakers.indices {
            if meeting.speakers[index].personID.map(sourceIDs.contains) == true {
                meeting.speakers[index].personID = targetID
            }
            if meeting.speakers[index].voiceReviewOrigin?.personID.map(sourceIDs.contains) == true {
                meeting.speakers[index].voiceReviewOrigin?.personID = targetID
            }
        }
    }

    /// Scan small metadata/content documents, including hidden review origins.
    /// Transcripts, recordings, notes, and summaries are neither loaded nor rewritten.
    func rewriteStoredMeeting(id: UUID, directory: URL, transaction: inout LibraryFileTransaction) throws
        -> MeetingListEntry?
    {
        let folder = try MeetingFolderLocation.resolve(id: id, directory: directory)
        let metadataURL = folder.appendingPathComponent("metadata.json")
        let contentURL = folder.appendingPathComponent("content.json")
        let metadataBytes = try Data(contentsOf: metadataURL)
        let contentBytes =
            FileManager.default.fileExists(atPath: contentURL.path) ? try Data(contentsOf: contentURL) : nil
        var entry = try JSONDecoder().decode(MeetingListEntry.self, from: metadataBytes)
        var content = try contentBytes.map { try JSONDecoder().decode(Meeting.self, from: $0) } ?? Meeting(id: id)
        guard entry.id == id, content.id == id else {
            throw MeetingError.message("The meeting ID does not match its folder.")
        }
        let original = content
        let originalEntry = entry
        apply(to: &content)
        entry.personIDs = replacing(entry.personIDs)
        guard content != original || entry != originalEntry else { return nil }
        try transaction.remember(metadataURL)
        if contentBytes != nil { try transaction.remember(contentURL) }
        guard try Data(contentsOf: metadataURL) == metadataBytes else {
            throw MeetingError.message("This meeting changed on disk. Try merging again.")
        }
        if let contentBytes, try Data(contentsOf: contentURL) != contentBytes {
            throw MeetingError.message("This meeting changed on disk. Try merging again.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if contentBytes != nil { try encoder.encode(content).write(to: contentURL, options: .atomic) }
        try encoder.encode(entry).write(to: metadataURL, options: .atomic)
        return entry
    }
}
