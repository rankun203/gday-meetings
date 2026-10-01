import Foundation

/// Audio-only folders are adopted without submitting transcription or summary work.
enum LibraryFolderImport {
    private static let audioExtensions: Set<String> = [
        "wav", "m4a", "mp3", "mp4", "aac", "aiff", "aif", "caf", "flac", "ogg", "opus",
    ]

    struct AudioFingerprint: Equatable {
        let name: String
        let size: Int
        let modified: Date?
    }
    static func fingerprints(_ folder: URL) throws -> [AudioFingerprint] {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
        return try files.compactMap { file in
            guard audioExtensions.contains(file.pathExtension.lowercased()) else { return nil }
            let value = try file.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard value.isRegularFile == true, value.isSymbolicLink != true else { return nil }
            return AudioFingerprint(
                name: file.lastPathComponent, size: value.fileSize ?? 0, modified: value.contentModificationDate)
        }.sorted { $0.name < $1.name }
    }

    static func adopt(_ folder: URL, root: URL, settleInterval: TimeInterval = 3) throws -> URL? {
        let manager = FileManager.default
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        try MeetingFolderLocation.validate(folder, directory: root)
        guard !manager.fileExists(atPath: folder.appendingPathComponent(".app-import").path) else { return nil }
        let metadata = folder.appendingPathComponent("metadata.json")
        // Preserve referenced IDs when an agent drops an already-described meeting.
        if manager.fileExists(atPath: metadata.path) {
            let entry = try JSONDecoder().decode(MeetingListEntry.self, from: Data(contentsOf: metadata))
            if let id = MeetingFolderLocation.identity(folder.lastPathComponent),
                folder.deletingLastPathComponent().standardizedFileURL.path
                    == root.appendingPathComponent("meetings").standardizedFileURL.path
            {
                guard entry.id == id else { throw MeetingError.message("Meeting ID differs from its folder.") }
                let existing = try MeetingFolderLocation.resolve(id: id, directory: root, date: entry.createdAt)
                guard existing.standardizedFileURL.path == folder.standardizedFileURL.path else {
                    try MeetingFolderLocation.registeredIndex(directory: root)?.quarantine(id: id)
                    throw MeetingFolderLocation.AccessError.duplicate
                }
                return nil
            }
            let target = try MeetingFolderLocation.resolve(id: entry.id, directory: root, date: entry.createdAt)
            guard target.standardizedFileURL.path != folder.standardizedFileURL.path else { return nil }
            guard !manager.fileExists(atPath: target.path) else {
                throw MeetingError.message(
                    "A meeting with this ID already exists. Change the imported meeting ID before importing it.")
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: folder, to: target)
            return target
        }
        let files = try manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        let audio = try files.filter {
            let properties = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return properties.isRegularFile == true && properties.isSymbolicLink != true
                && audioExtensions.contains($0.pathExtension.lowercased())
        }
        guard !audio.isEmpty else { return nil }
        for file in files {
            let modification =
                try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modification) < settleInterval { throw ImportPending() }
        }
        var meeting = Meeting()
        meeting.id = MeetingFolderLocation.identity(folder.lastPathComponent) ?? MeetingIdentity.newID()
        meeting.title = folder.lastPathComponent
        meeting.createdAt = try folder.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()
        meeting.audioFiles = audio.map(\.lastPathComponent).sorted()
        var target = try MeetingFolderLocation.resolve(id: meeting.id, directory: root, date: meeting.createdAt)
        while target.standardizedFileURL.path != folder.standardizedFileURL.path
            && manager.fileExists(atPath: target.path)
        {
            meeting.id = MeetingIdentity.newID()
            target = try MeetingFolderLocation.resolve(id: meeting.id, directory: root, date: meeting.createdAt)
        }
        if target.standardizedFileURL.path != folder.standardizedFileURL.path {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: folder, to: target)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(MeetingListEntry(meeting)).write(
            to: target.appendingPathComponent("metadata.json"), options: .atomic)
        return target
    }

    /// Runs on the reconciliation worker, opens container headers without decoding the recording.
    static func updateDuration(_ folder: URL) throws {
        let metadata = folder.appendingPathComponent("metadata.json")
        let original = try Data(contentsOf: metadata)
        var entry = try JSONDecoder().decode(MeetingListEntry.self, from: original)
        guard entry.duration == 0 else { return }
        var duration: Double = 0
        for name in entry.audioFiles {
            guard URL(fileURLWithPath: name).lastPathComponent == name, !name.contains("..") else { continue }
            let reader = try StreamingAudioReader.open(folder.appendingPathComponent(name))
            duration = max(duration, Double(reader.totalFrames) / StreamingAudioReader.sampleRate)
        }
        guard duration.isFinite, duration > 0, try Data(contentsOf: metadata) == original else { return }
        entry.duration = duration
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: metadata, options: .atomic)
    }

    struct ImportPending: Error {}
}
