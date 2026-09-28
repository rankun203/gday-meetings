import Foundation

/// Append-only committed events. Only a torn, non-newline-terminated final write
/// is discarded before the next append. Complete corrupt records block writes.
/// Callers serialize access on MeetingStore's main actor.
final class ManagedTaskJournal {
    struct Cursor: Codable, Equatable {
        let createdAt: Date
        let id: UUID
    }
    private struct Event: Codable {
        enum Operation: String, Codable { case upsert, delete }
        var schemaVersion = 1
        var eventID = UUID()
        var writtenAt = Date()
        let operation: Operation
        let taskID: UUID
        let record: ManagedTaskRecord?
    }
    let url: URL
    private(set) var records: [UUID: ManagedTaskRecord] = [:]
    /// Latest event offsets can seed a disk-backed index without rewriting events.
    private(set) var latestOffsets: [UUID: UInt64] = [:]
    private struct Revision: Equatable {
        let size: UInt64
        let modified: Date?
        let inode: UInt64
    }
    private var knownRevision: Revision?
    private var diskRevision: Revision? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Revision(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
    var hasExternalChanges: Bool { diskRevision != knownRevision }
    private var loaded = false
    private var committedLength: UInt64 = 0
    private var observedLength: UInt64 = 0
    private var hasIncompleteTail = false
    private var writeFailure: Error?
    init(url: URL) { self.url = url }

    @discardableResult func load() throws -> [ManagedTaskRecord] {
        records = [:]
        latestOffsets = [:]
        committedLength = 0
        observedLength = 0
        hasIncompleteTail = false
        writeFailure = nil
        loaded = false
        guard FileManager.default.fileExists(atPath: url.path) else {
            loaded = true
            knownRevision = nil
            return []
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var buffer = Data()
            let decoder = JSONDecoder()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                observedLength += UInt64(chunk.count)
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    guard !line.isEmpty else { throw ServiceError("The task journal contains an empty record.") }
                    let event = try decoder.decode(Event.self, from: line)
                    guard event.schemaVersion == 1 else {
                        throw ServiceError("This task journal uses an unsupported format.")
                    }
                    switch event.operation {
                    case .upsert:
                        guard let record = event.record, record.id == event.taskID else {
                            throw ServiceError("The task journal contains an invalid task identity.")
                        }
                        records[event.taskID] = record
                        latestOffsets[event.taskID] = committedLength
                    case .delete:
                        guard event.record == nil else {
                            throw ServiceError("The task journal contains an invalid deletion.")
                        }
                        records.removeValue(forKey: event.taskID)
                        latestOffsets.removeValue(forKey: event.taskID)
                    }
                    let bytes = buffer.distance(from: buffer.startIndex, to: newline) + 1
                    committedLength += UInt64(bytes)
                    buffer.removeFirst(bytes)
                }
                guard buffer.count <= 8 * 1_024 * 1_024 else {
                    throw ServiceError("A task journal record exceeds the supported size.")
                }
            }
            hasIncompleteTail = !buffer.isEmpty
            loaded = true
            knownRevision = diskRevision
            return page(limit: Int.max)
        }
        catch {
            writeFailure = error
            throw ServiceError("Couldn’t read tasks.jsonl. The file was kept unchanged. \(error.localizedDescription)")
        }
    }

    func upsert(_ record: ManagedTaskRecord) throws {
        try append(Event(operation: .upsert, taskID: record.id, record: record))
    }
    func delete(_ id: UUID) throws {
        try append(Event(operation: .delete, taskID: id, record: nil))
    }
    private func append(_ event: Event) throws {
        if let writeFailure { throw writeFailure }
        if !loaded { try load() }
        var data = try JSONEncoder().encode(event)
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw ServiceError("Couldn’t create tasks.jsonl.")
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        do {
            guard try handle.seekToEnd() == observedLength else {
                throw ServiceError(
                    "The task journal changed outside this app. Reopen the library before changing tasks.")
            }
            if hasIncompleteTail {
                try handle.truncate(atOffset: committedLength)
                try handle.synchronize()
                hasIncompleteTail = false
            }
            let offset = try handle.seekToEnd()
            guard offset == committedLength else {
                throw ServiceError(
                    "The task journal changed outside this app. Reopen the library before changing tasks.")
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            committedLength += UInt64(data.count)
            observedLength = committedLength
            if let disk = diskRevision {
                knownRevision = Revision(size: committedLength, modified: disk.modified, inode: disk.inode)
            }
            if let record = event.record {
                records[event.taskID] = record
                latestOffsets[event.taskID] = offset
            }
            else {
                records.removeValue(forKey: event.taskID)
                latestOffsets.removeValue(forKey: event.taskID)
            }
        }
        catch {
            // Reopen/replay before any later append: a write may have stopped mid-line.
            writeFailure = error
            throw error
        }
    }

    /// Stable cursor ordering; updates never move a row because createdAt is immutable.
    /// Replay currently indexes latest rows in memory. A persisted offset index is
    /// needed to make cold-start/history pagination independent of total log size.
    func page(after cursor: Cursor? = nil, limit: Int = 50) -> [ManagedTaskRecord] {
        records.values.filter { row in
            guard let cursor else { return true }
            return row.createdAt < cursor.createdAt
                || (row.createdAt == cursor.createdAt && row.id.uuidString < cursor.id.uuidString)
        }.sorted(by: Self.newestFirst).prefix(max(0, limit)).map { $0 }
    }
    static func newestFirst(_ lhs: ManagedTaskRecord, _ rhs: ManagedTaskRecord) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.createdAt > rhs.createdAt
    }
}
