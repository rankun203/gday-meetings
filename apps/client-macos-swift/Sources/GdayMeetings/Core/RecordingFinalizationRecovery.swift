import Foundation

/// A failed metadata save must not leave finalized capture information only in memory.
struct RecordingFinalizationRecovery: Codable {
    static let filename = "recording-finalization-recovery.json"
    var baseline: Meeting
    var proposed: Meeting

    func write(at folder: URL) throws {
        try PrivateTranscriptFile.write(JSONEncoder().encode(self), name: Self.filename, at: folder)
    }

    static func read(at folder: URL) throws -> Self? {
        let file = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try PrivateTranscriptFile.validatePath(name: filename, at: folder)
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    static func remove(at folder: URL) throws {
        let file = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: file.path) {
            try PrivateTranscriptFile.validatePath(name: filename, at: folder)
            try FileManager.default.removeItem(at: file)
        }
    }
}

extension MeetingStore {
    func recoverRecordingFinalization(id: UUID) async -> Bool {
        guard libraryWritable else { return false }
        guard recordingID != id else { return true }
        let folder = directory(for: id)
        let generation = externalReloadGeneration
        let root = dataDirectory
        do {
            guard
                let recovery = try await Task.detached(
                    priority: .utility,
                    operation: {
                        try RecordingFinalizationRecovery.read(at: folder)
                    }
                ).value
            else { return true }
            return await enqueueCanonical {
                guard self.libraryWritable, self.recordingID != id,
                    self.dataDirectory == root, self.externalReloadGeneration == generation,
                    let index = self.meetings.firstIndex(where: { $0.id == id }),
                    recovery.baseline.id == id, recovery.proposed.id == id
                else { return false }
                do {
                    let notes = self.meetings[index].notes
                    self.meetings[index] = try RecordingMeetingMerge.merge(
                        baseline: recovery.baseline, proposed: recovery.proposed, disk: self.meetings[index])
                    self.meetings[index].notes = notes
                    guard await self.performCanonicalSave(meetingID: id) else { return false }
                    try await Task.detached(priority: .utility) {
                        try RecordingFinalizationRecovery.remove(at: folder)
                    }.value
                    return true
                }
                catch {
                    self.errorMessage =
                        "Couldn’t finish saving the recording. Its recovery information was kept. "
                        + error.localizedDescription
                    return false
                }
            }
        }
        catch {
            errorMessage = "Couldn’t read the recording’s recovery information. " + error.localizedDescription
            return false
        }
    }
}
