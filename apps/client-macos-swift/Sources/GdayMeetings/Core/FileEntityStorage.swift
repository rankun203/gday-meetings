import Foundation

/// Small independently editable entity documents. The database never owns these records.
enum FileEntityStorage {
    static func load<T: Decodable & Identifiable>(_ type: T.Type, kind: String, directory: URL) throws -> [T]
    where T.ID == UUID {
        let root = directory.appendingPathComponent(kind, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var identities = Set<UUID>()
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw MeetingError.message(
                    "The \(kind) folder contains an unsupported document: \(url.lastPathComponent).")
            }
            let record = try JSONDecoder().decode(type, from: Data(contentsOf: url))
            guard url.deletingPathExtension().lastPathComponent == record.id.uuidString,
                identities.insert(record.id).inserted
            else {
                throw MeetingError.message(
                    "The \(kind) document ID does not match its filename: \(url.lastPathComponent).")
            }
            return record
        }
    }

    static func save<T: Codable & Identifiable & Equatable>(
        _ records: [T], previous: [T], kind: String, directory: URL
    ) throws where T.ID == UUID {
        let root = directory.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let ids = Set(records.map(\.id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for record in records where old[record.id] != record {
            let url = root.appendingPathComponent(record.id.uuidString + ".json")
            if let baseline = old[record.id], FileManager.default.fileExists(atPath: url.path) {
                let disk = try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
                guard disk == baseline || disk == record else {
                    throw MeetingError.message("This \(kind) document changed on disk. Reload it before saving.")
                }
            }
            try encoder.encode(record).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        for record in previous where !ids.contains(record.id) {
            let url = root.appendingPathComponent(record.id.uuidString + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let disk = try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            guard disk == record else {
                throw MeetingError.message("This \(kind) document changed on disk. Reload it before deleting.")
            }
            try FileManager.default.removeItem(at: url)
        }
    }
}
