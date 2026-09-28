import CryptoKit
import Foundation

/// Provider metadata (language and model lists) saved per provider, so views can
/// show it without contacting the provider. Each entry records the non-secret
/// configuration it describes; a different endpoint makes the entry unusable.
@MainActor final class ProviderMetadataCache<Value: Codable & Equatable> {
    struct Entry: Codable, Equatable {
        let providerID: UUID
        let fingerprint: String
        let value: Value
        let fetchedAt: Date
    }
    private let directory: URL
    private let fileName: String
    /// A read-only library (for example one saved by a newer app version) must not gain files.
    private let canWrite: () -> Bool
    private(set) var entries: [UUID: Entry] = [:]

    init(directory: URL, fileName: String, canWrite: @escaping () -> Bool = { true }) {
        self.directory = directory.appendingPathComponent("providers", isDirectory: true)
        self.fileName = fileName
        self.canWrite = canWrite
    }

    /// Hashes configuration fields so the file names no endpoint or credential.
    nonisolated static func fingerprint(_ fields: [String]) -> String {
        SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entry(providerID: UUID, fingerprint: String) -> Entry? {
        if entries[providerID] == nil,
            let data = try? Data(contentsOf: fileURL(providerID)),
            let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.providerID == providerID
        {
            entries[providerID] = entry
        }
        return entries[providerID].flatMap { $0.fingerprint == fingerprint ? $0 : nil }
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Saves the entry and drops entries for providers that no longer exist.
    func store(_ entry: Entry, keeping providerIDs: Set<UUID>) {
        entries[entry.providerID] = entry
        entries = entries.filter { providerIDs.contains($0.key) }
        guard canWrite() else { return }
        guard providerIDs.contains(entry.providerID) else {
            try? FileManager.default.removeItem(at: fileURL(entry.providerID))
            return
        }
        // The in-memory entry stays usable if the write fails; it is loaded again next time.
        let files = FileManager.default
        let url = fileURL(entry.providerID)
        do {
            try files.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            for folder in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: folder.lastPathComponent), !providerIDs.contains(id) else { continue }
                // Other provider data belongs to its own store; remove only this cache.
                try? files.removeItem(at: folder.appendingPathComponent(fileName))
            }
        }
        catch {}
    }
}
