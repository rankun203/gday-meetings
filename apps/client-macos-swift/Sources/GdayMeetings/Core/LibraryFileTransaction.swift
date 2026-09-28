import Foundation

/// A bounded write-ahead rollback journal for the documents touched by one save.
/// The index is derived and is updated only after committing these files.
struct LibraryFileTransaction {
    private struct Entry: Codable {
        let path: String
        let backup: String?
    }
    let root: URL
    private var entries: [Entry] = []
    private var journal: URL { root.appendingPathComponent(".document-transaction") }
    init(root: URL) { self.root = root }
    mutating func remember(_ url: URL) throws {
        guard url.path.hasPrefix(root.path + "/") else { throw MeetingError.message("Invalid document path.") }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        guard !entries.contains(where: { $0.path == relative }) else { return }
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let name = exists ? String(entries.count) : nil
        if let name { try FileManager.default.copyItem(at: url, to: journal.appendingPathComponent(name)) }
        entries.append(Entry(path: relative, backup: name))
        try JSONEncoder().encode(entries).write(to: journal.appendingPathComponent("manifest.json"), options: .atomic)
    }
    func commit() throws {
        if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
    }
    func restore() throws {
        for entry in entries.reversed() {
            guard !entry.path.split(separator: "/").contains(".."), !entry.path.hasPrefix("/") else {
                throw MeetingError.message("Invalid document journal.")
            }
            let destination = root.appendingPathComponent(entry.path)
            if let backup = entry.backup {
                try Data(contentsOf: journal.appendingPathComponent(backup)).write(to: destination, options: .atomic)
            }
            else if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
        }
        try commit()
    }
    static func recover(root: URL) throws {
        var transaction = Self(root: root)
        let manifest = transaction.journal.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        transaction.entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifest))
        try transaction.restore()
    }
}
