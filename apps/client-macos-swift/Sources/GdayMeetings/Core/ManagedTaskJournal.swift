import CryptoKit
import Foundation

/// Append-only committed events. Only a torn, non-newline-terminated final write
/// is discarded before the next append. Complete corrupt records block writes.
/// A recursive lock serializes background index reads/rebuilds and durable intent writes.
final class ManagedTaskJournal: @unchecked Sendable {
    struct Cursor: Codable, Equatable, Sendable {
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
    private let lock = NSRecursiveLock()
    let indexURL: URL
    private var index: ManagedTaskIndex?
    private(set) var replayedEventCount = 0
    // Diagnostic compatibility; production paging never materializes this dictionary.
    var latestOffsets: [UUID: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        guard let index, let locations = try? index.locations(limit: Int.max) else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: locations.compactMap { location in
                guard let record = try? read(location) else { return nil }
                return (record.id, location.offset)
            })
    }
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
    var hasExternalChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return diskRevision != knownRevision
    }
    private var revisionKey: String {
        guard let revision = diskRevision else { return "missing" }
        return "\(revision.size):\(revision.inode):\(revision.modified?.timeIntervalSince1970 ?? 0)"
    }
    private var loaded = false
    private var comparedPreviousOffsets = false
    private var committedLength: UInt64 = 0
    private var observedLength: UInt64 = 0
    private var hasIncompleteTail = false
    private var writeFailure: Error?
    private var storedReadFailure: Error?
    var readFailure: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedReadFailure
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedReadFailure = newValue
        }
    }
    init(url: URL, indexURL: URL? = nil) {
        self.url = url
        self.indexURL = indexURL ?? url.deletingLastPathComponent().appendingPathComponent("index.db")
    }

    @discardableResult func load() throws -> [ManagedTaskRecord] {
        try prepare()
        return try query(limit: Int.max)
    }

    /// Warm opens only inspect the journal revision. Cold rebuilds stream one event at a time.
    func prepare(forceRebuild: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        replayedEventCount = 0
        comparedPreviousOffsets = false
        readFailure = nil
        let startingRevision = diskRevision
        let startingKey = revisionKey
        // Release this journal's old connection before opening. Central recovery never
        // replaces a file that another domain still has open.
        index = nil
        index = try ManagedTaskIndex(url: indexURL)
        guard let index else { throw ServiceError("Couldn’t open the task index.") }
        if !forceRebuild, let (revision, committed) = try index.revision(), revision == revisionKey {
            committedLength = committed
            observedLength = diskRevision?.size ?? 0
            hasIncompleteTail = observedLength != committed
            loaded = true
            writeFailure = nil
            knownRevision = diskRevision
            return
        }
        do {
            try index.clear()
            comparedPreviousOffsets = true
        }
        catch {
            index.discardRebuild()
            throw error
        }
        committedLength = 0
        observedLength = 0
        hasIncompleteTail = false
        writeFailure = nil
        loaded = false
        guard FileManager.default.fileExists(atPath: url.path) else {
            do {
                try index.setRevision(revisionKey, committed: 0)
                try index.publishRebuild()
                loaded = true
                knownRevision = nil
            }
            catch {
                index.discardRebuild()
                writeFailure = error
                throw error
            }
            return
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
                        try index.upsert(
                            record, offset: committedLength, length: line.count,
                            digest: SHA256.hash(data: line).description)
                    case .delete:
                        guard event.record == nil else {
                            throw ServiceError("The task journal contains an invalid deletion.")
                        }
                        try index.remove(event.taskID)
                    }
                    replayedEventCount += 1
                    let bytes = buffer.distance(from: buffer.startIndex, to: newline) + 1
                    committedLength += UInt64(bytes)
                    buffer.removeFirst(bytes)
                }
                guard buffer.count <= 8 * 1_024 * 1_024 else {
                    throw ServiceError("A task journal record exceeds the supported size.")
                }
            }
            guard diskRevision == startingRevision else {
                throw ServiceError(
                    "The task journal changed during indexing. Reopen the library to read the updated file.")
            }
            hasIncompleteTail = !buffer.isEmpty
            try index.setRevision(startingKey, committed: committedLength)
            try index.publishRebuild()
            loaded = true
            knownRevision = diskRevision
        }
        catch {
            index.discardRebuild()
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
        lock.lock()
        defer { lock.unlock() }
        if let writeFailure { throw writeFailure }
        if let readFailure { throw readFailure }
        if !loaded { try prepare() }
        var data = try JSONEncoder().encode(event)
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw ServiceError("Couldn’t create tasks.jsonl.")
            }
            knownRevision = diskRevision
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        do {
            guard diskRevision == knownRevision, try handle.seekToEnd() == observedLength else {
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
                try index?.upsert(
                    record, offset: offset, length: data.count - 1,
                    digest: SHA256.hash(data: data.dropLast()).description)
            }
            else {
                try index?.remove(event.taskID)
            }
            try index?.setRevision(revisionKey, committed: committedLength)
        }
        catch {
            // Reopen/replay before any later append: a write may have stopped mid-line.
            writeFailure = error
            throw error
        }
    }

    private func read(_ location: ManagedTaskIndex.Location) throws -> ManagedTaskRecord {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: location.offset)
        guard let data = try handle.read(upToCount: location.length), data.count == location.length,
            SHA256.hash(data: data).description == location.digest,
            let record = try JSONDecoder().decode(Event.self, from: data).record,
            record.id.uuidString == location.id
        else {
            throw ServiceError("The task index no longer matches the journal.")
        }
        return record
    }

    func query(
        where predicate: String = "1", order: String = "created DESC,id DESC", limit: Int = 50,
        recoverIndex: Bool = true
    ) throws
        -> [ManagedTaskRecord]
    {
        lock.lock()
        defer { lock.unlock() }
        do {
            if !loaded { try prepare() }
            guard diskRevision == knownRevision else {
                throw ServiceError(
                    "The task journal changed outside this app. Wait for it to reload before changing tasks.")
            }
            let records = try index?.locations(where: predicate, order: order, limit: limit).map(read) ?? []
            guard diskRevision == knownRevision else {
                throw ServiceError("The task journal changed while reading tasks.")
            }
            return records
        }
        catch {
            if recoverIndex, diskRevision == knownRevision, writeFailure == nil {
                do {
                    try prepare(forceRebuild: true)
                    return try query(where: predicate, order: order, limit: limit, recoverIndex: false)
                }
                catch {
                    readFailure = error
                    throw error
                }
            }
            readFailure = error
            throw error
        }
    }
    func count(where predicate: String = "1") -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (try? index?.count(where: predicate)) ?? 0
    }
    func changedSinceRebuild(_ id: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard comparedPreviousOffsets else { return true }
        return try index?.changedSinceRebuild(id) ?? true
    }
    func record(id: UUID) -> ManagedTaskRecord? {
        try? query(where: "id=" + ManagedTaskIndex.literal(id.uuidString), limit: 1).first
    }
    /// Stable creation ordering; cursor predicates are evaluated by the disk index.
    func page(after cursor: Cursor? = nil, limit: Int = 50, predicate: String = "1", newer: Bool = false)
        -> [ManagedTaskRecord]
    {
        var condition = predicate
        if let cursor {
            let comparison = newer ? ">" : "<"
            let date = cursor.createdAt.timeIntervalSince1970
            condition +=
                " AND (created \(comparison) \(date) OR (created=\(date) AND id \(comparison) \(ManagedTaskIndex.literal(cursor.id.uuidString))))"
        }
        do {
            let rows = try query(where: condition, order: newer ? "created,id" : "created DESC,id DESC", limit: limit)
            return newer ? rows.reversed() : rows
        }
        catch {
            lock.lock()
            readFailure = error
            lock.unlock()
            return []
        }
    }
    static func newestFirst(_ lhs: ManagedTaskRecord, _ rhs: ManagedTaskRecord) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.createdAt > rhs.createdAt
    }
}
