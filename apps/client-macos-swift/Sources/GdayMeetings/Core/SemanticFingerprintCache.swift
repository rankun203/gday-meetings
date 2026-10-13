import Foundation

/// File stamps only avoid re-reading unchanged canonical sources. Search task
/// admission still compares the content projection, never these stamps.
actor SemanticFingerprintCache {
    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date?
        let created: Date?
        let inode: UInt64
    }
    private struct Entry {
        let stamps: [Stamp?]
        let fingerprint: String
        var access: UInt64
    }
    private var entries: [String: Entry] = [:]
    private var access: UInt64 = 0
    private let capacity: Int
    private(set) var canonicalReads = 0

    init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    func fingerprint(folder: URL) throws -> String {
        try MeetingFolderLocation.validate(
            folder, directory: folder.deletingLastPathComponent().deletingLastPathComponent())
        let stamps = try stamps(folder)
        let key = folder.standardizedFileURL.path
        access &+= 1
        if var cached = entries[key], cached.stamps == stamps {
            cached.access = access
            entries[key] = cached
            return cached.fingerprint
        }
        canonicalReads += 1
        let fingerprint = try SemanticSource.fingerprint(folder: folder)
        // Never cache a mixed snapshot if another writer changed a source while it
        // was read. The next quiet scan will retry the complete committed content.
        guard try self.stamps(folder) == stamps else { throw SearchProviderError.sourceChanged }
        if entries[key] == nil, entries.count >= capacity,
            let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key
        {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = .init(stamps: stamps, fingerprint: fingerprint, access: access)
        return fingerprint
    }

    private func stamps(_ folder: URL) throws -> [Stamp?] {
        try [
            "metadata.json", "content.json", "transcript.jsonl", "transcript.json", "live-transcript.json",
            "notes.md", "summary.md", LiveTranscriptProjection.checkpointName,
        ].map { name in
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular else {
                throw SearchProviderError.invalidResponse
            }
            return Stamp(
                size: (values[.size] as? NSNumber)?.uint64Value ?? 0,
                modified: values[.modificationDate] as? Date,
                created: values[.creationDate] as? Date,
                inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        }
    }
}
