import CryptoKit
import Darwin
import Foundation

struct VoiceLibraryRepresentations: Codable, Equatable {
    var embeddings: [TypedVoiceEmbedding]
}

/// Authoritative JSON records, with one durable redo transaction. A job update
/// touches its own record; it never serializes example vectors or the library.
final class VoiceLibraryPersistence {
    struct Snapshot: Sendable {
        var revision: UUID?
        var fileRevisions: [String: String]
        var write: (@Sendable (Data, URL) throws -> Void)?
    }
    func snapshot() -> Snapshot { Snapshot(revision: revision, fileRevisions: fileRevisions, write: writeOverride) }
    func adopt(_ value: Snapshot) {
        revision = value.revision
        fileRevisions = value.fileRevisions
    }
    private struct Header: Codable {
        var version = 1
        var revision: UUID
    }
    fileprivate struct Change: Codable, Sendable {
        var path: String
        var data: Data?
    }
    fileprivate struct Transaction: Codable, Sendable {
        var version = 1
        var previousRevision: UUID?
        var revision: UUID
        var changes: [Change]
    }
    let directory: URL
    private let writable: Bool
    private var revision: UUID?
    private var fileRevisions: [String: String] = [:]
    private var lockDescriptor: Int32 = -1
    private var externalLockHeld = false
    private var externalPaths: [String] = []
    private var externalOriginalRevision: UUID?
    private var externalNextRevision: UUID?
    private let writeOverride: (@Sendable (Data, URL) throws -> Void)?
    private(set) var maintenanceWarning: String?
    /// Test seam at the last reversible point, before the durable commit marker.
    var beforeCommit: (() throws -> Void)?

    init(directory libraryDirectory: URL, writable: Bool = true, write: (@Sendable (Data, URL) throws -> Void)? = nil)
        throws
    {
        writeOverride = write
        directory = libraryDirectory.appendingPathComponent("voice-library", isDirectory: true)
        self.writable = writable
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.appendingPathComponent("state.json").path),
            !manager.fileExists(atPath: directory.appendingPathComponent("transaction.json").path),
            manager.fileExists(atPath: libraryDirectory.appendingPathComponent("voice-library.json").path)
        {
            throw ServiceError(
                "The voice library needs a one-time storage migration. Quit Gday Meetings and run scripts/migrate_voice_library.py for this data folder. The existing file has been kept."
            )
        }
        if writable {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if manager.fileExists(atPath: directory.path) {
            try rejectSymbolicLink(directory)
            let lock = directory.appendingPathComponent(".lock")
            if manager.fileExists(atPath: lock.path) { try rejectSymbolicLink(lock) }
            lockDescriptor = Darwin.open(lock.path, writable ? O_RDWR | O_CREAT : O_RDONLY, 0o600)
            guard lockDescriptor >= 0 else { throw ServiceError("Couldn’t lock the voice library.") }
        }
    }

    deinit { if lockDescriptor >= 0 { Darwin.close(lockDescriptor) } }

    func load(includeRepresentations: Bool = false) throws -> VoiceLibraryDocument? {
        try locked {
            let transaction = try pendingTransaction()
            if writable, let transaction { materializeCommitted(transaction) }
            let header = try readHeader()
            revision = transaction?.revision ?? header?.revision
            try captureFileRevisions()
            guard revision != nil else { return nil }
            let overlay = transaction.map { Dictionary(uniqueKeysWithValues: $0.changes.map { ($0.path, $0) }) } ?? [:]
            var result = VoiceLibraryDocument()
            result.examples = try readRecords("examples", overlay: overlay, as: VoiceExample.self)
            result.decisions = try readRecords("decisions", overlay: overlay, as: VoiceSpeakerDecision.self)
            result.jobs = try readRecords("jobs", overlay: overlay, as: VoicePreparationJob.self)
            result.undo = try readRecords("undo", overlay: overlay, as: VoiceLibraryUndo.self)
            result.deletedPersonIDs = try readRecords("deleted-people", overlay: overlay, as: UUID.self)
            guard Set(result.examples.map(\.id)).count == result.examples.count,
                Set(result.jobs.map(\.id)).count == result.jobs.count,
                Set(result.decisions).count == result.decisions.count
            else { throw ServiceError("The voice library contains duplicate record identifiers.") }
            if includeRepresentations {
                for index in result.examples.indices {
                    if let value: VoiceLibraryRepresentations = try readRecord(
                        path: representationPath(result.examples[index].id), overlay: overlay)
                    {
                        result.examples[index].embeddings = value.embeddings
                    }
                }
            }
            return result
        }
    }

    func loadRepresentations(exampleID: UUID) throws -> VoiceLibraryRepresentations? {
        try locked {
            let transaction = try pendingTransaction()
            let current = try transaction?.revision ?? readHeader()?.revision
            guard current == revision else { throw changedError() }
            let overlay = transaction.map { Dictionary(uniqueKeysWithValues: $0.changes.map { ($0.path, $0) }) } ?? [:]
            let path = representationPath(exampleID)
            if overlay[path] == nil {
                guard VoiceLibraryStore.revision(url: try recordURL(path)) == fileRevisions[path] else {
                    throw changedError()
                }
            }
            return try readRecord(path: path, overlay: overlay)
        }
    }

    /// Snapshot the precise reviewed records needed by a profile. Unrelated live
    /// candidate commits must not cancel expensive reviewed-profile construction.
    func profileDependencyRevisions(exampleIDs: [UUID]) throws -> [String: String] {
        try locked { try validateRevision() }
        let paths = exampleIDs.flatMap { ["examples/\($0.uuidString).json", representationPath($0)] }
        var result: [String: String] = [:]
        for start in stride(from: 0, to: paths.count, by: 32) {
            try Task.checkCancellation()
            let batch = paths[start..<min(paths.count, start + 32)]
            let revisions = try locked {
                let transaction = try pendingTransaction()
                let overlay =
                    transaction.map { Dictionary(uniqueKeysWithValues: $0.changes.map { ($0.path, $0) }) } ?? [:]
                var values: [String: String] = [:]
                for path in batch {
                    try Task.checkCancellation()
                    if overlay[path] != nil {
                        // A newer transaction may touch unrelated candidates, but
                        // it must not replace one of this profile's dependencies.
                        guard transaction?.revision == revision else { throw changedError() }
                        values[path] = try dependencyRevision(path, overlay: overlay)
                    }
                    else {
                        let observed = VoiceLibraryStore.revision(url: try recordURL(path))
                        guard observed == fileRevisions[path] else { throw changedError() }
                        values[path] = observed ?? "absent"
                    }
                }
                return values
            }
            result.merge(revisions, uniquingKeysWith: { _, new in new })
        }
        return result
    }

    func loadProfileRepresentations(exampleID: UUID, dependencies: [String: String]) throws
        -> VoiceLibraryRepresentations?
    {
        try locked {
            let overlay =
                try pendingTransaction().map { Dictionary(uniqueKeysWithValues: $0.changes.map { ($0.path, $0) }) }
                ?? [:]
            for path in ["examples/\(exampleID.uuidString).json", representationPath(exampleID)] {
                guard try dependencyRevision(path, overlay: overlay) == dependencies[path] else { throw changedError() }
            }
            return try readRecord(path: representationPath(exampleID), overlay: overlay)
        }
    }

    func validateProfileDependencies(_ dependencies: [String: String]) throws {
        let paths = dependencies.keys.sorted()
        for start in stride(from: 0, to: paths.count, by: 32) {
            try Task.checkCancellation()
            try locked {
                let overlay =
                    try pendingTransaction().map { Dictionary(uniqueKeysWithValues: $0.changes.map { ($0.path, $0) }) }
                    ?? [:]
                for path in paths[start..<min(paths.count, start + 32)] {
                    try Task.checkCancellation()
                    guard try dependencyRevision(path, overlay: overlay) == dependencies[path] else {
                        throw changedError()
                    }
                }
            }
        }
    }

    private func dependencyRevision(_ path: String, overlay: [String: Change]) throws -> String {
        if let change = overlay[path] {
            return change.data.map {
                "transaction:" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            } ?? "absent"
        }
        return VoiceLibraryStore.revision(url: try recordURL(path)) ?? "absent"
    }

    func validateCurrentRevision() throws {
        try locked { try validateRevision() }
    }

    func validateRepresentationRevision(exampleID: UUID) throws {
        try validateRecordRevision(path: representationPath(exampleID))
    }

    func validateMatchingMetadataRevisions() throws {
        let paths = fileRevisions.keys.filter { $0.hasPrefix("examples/") || $0.hasPrefix("deleted-people/") }.sorted()
        for start in stride(from: 0, to: paths.count, by: 32) {
            try Task.checkCancellation()
            try locked {
                try validateRevision()
                let overlay = try pendingTransaction().map { Set($0.changes.map(\.path)) } ?? []
                for path in paths[start..<min(paths.count, start + 32)] {
                    try Task.checkCancellation()
                    if !overlay.contains(path),
                        VoiceLibraryStore.revision(url: try recordURL(path)) != fileRevisions[path]
                    {
                        throw changedError()
                    }
                }
            }
        }
    }

    private func validateRecordRevision(path: String) throws {
        try locked {
            let transaction = try pendingTransaction()
            let current = try transaction?.revision ?? readHeader()?.revision
            guard current == revision else { throw changedError() }
            if transaction?.changes.contains(where: { $0.path == path }) != true {
                guard VoiceLibraryStore.revision(url: try recordURL(path)) == fileRevisions[path] else {
                    throw changedError()
                }
            }
        }
    }

    struct PreparedCommit: Sendable {
        fileprivate var transaction: Transaction
        fileprivate var encoded: Data
        fileprivate var fileRevisions: [String: String]
        fileprivate var readPaths: Set<String>
    }

    /// Read-only preparation against this backend's adopted snapshot. Run on a
    /// worker; it creates no files and acquires no writer reservation.
    func prepare(previous: VoiceLibraryDocument, next: VoiceLibraryDocument) throws -> PreparedCommit {
        try Task.checkCancellation()
        var previous = previous
        let desired = Dictionary(uniqueKeysWithValues: next.examples.map { ($0.id, $0) })
        let readPaths = Set(
            previous.examples.compactMap { value in
                desired[value.id]?.embeddings.isEmpty == false ? representationPath(value.id) : nil
            })
        // Metadata-only callers need not synchronously load selected vectors.
        // Read only prior representations that the desired document supplies,
        // so an unchanged vector does not get rewritten on every live update.
        for index in previous.examples.indices
        where previous.examples[index].embeddings.isEmpty
            && desired[previous.examples[index].id]?.embeddings.isEmpty == false
        {
            try Task.checkCancellation()
            previous.examples[index].embeddings =
                try loadRepresentations(exampleID: previous.examples[index].id)?.embeddings ?? []
        }
        let changes = try changes(previous: previous, next: next)
        let transaction = Transaction(previousRevision: revision, revision: UUID(), changes: changes)
        let data = try encode(transaction)
        guard data.count <= 64 * 1024 * 1024 else {
            throw ServiceError("This voice-library change is too large. Save fewer examples at a time.")
        }
        try Task.checkCancellation()
        return PreparedCommit(
            transaction: transaction, encoded: data, fileRevisions: fileRevisions, readPaths: readPaths)
    }

    /// Caller must also validate its in-memory review document before publishing.
    func commit(_ prepared: PreparedCommit) throws {
        guard writable else { throw ServiceError("The voice library is read-only.") }
        try locked {
            let transaction = prepared.transaction
            guard revision == transaction.previousRevision else { throw changedError() }
            for path in Set(transaction.changes.map(\.path)).union(prepared.readPaths) {
                guard fileRevisions[path] == prepared.fileRevisions[path] else { throw changedError() }
            }
            try validateRevision()
            if let pending = try pendingTransaction() {
                try apply(pending)
                try refreshFileRevisions(pending.changes.map(\.path))
            }
            try validateFiles(transaction.changes)
            // A vector read during preparation can suppress a representation
            // write. It remains a dependency even when only metadata changes.
            let writtenPaths = Set(transaction.changes.map(\.path))
            try validateFiles(prepared.readPaths.subtracting(writtenPaths).map { Change(path: $0, data: nil) })
            guard !transaction.changes.isEmpty || revision == nil else { return }
            try beforeCommit?()
            do { try atomicWrite(prepared.encoded, to: directory.appendingPathComponent("transaction.json")) }
            catch {
                guard (try? pendingTransaction()?.revision) == transaction.revision else { throw error }
            }
            revision = transaction.revision
            materializeCommitted(transaction)
        }
    }

    func commit(previous: VoiceLibraryDocument, next: VoiceLibraryDocument) throws {
        guard writable else { throw ServiceError("The voice library is read-only.") }
        try locked {
            try validateRevision()
            if let pending = try pendingTransaction() {
                try apply(pending)
                try refreshFileRevisions(pending.changes.map(\.path))
            }
            let changes = try changes(previous: previous, next: next)
            try validateFiles(changes)
            guard !changes.isEmpty || revision == nil else { return }
            let transaction = Transaction(previousRevision: revision, revision: UUID(), changes: changes)
            let data = try encode(transaction)
            guard data.count <= 64 * 1024 * 1024 else {
                throw ServiceError("This voice-library change is too large. Save fewer examples at a time.")
            }
            try beforeCommit?()
            do {
                try atomicWrite(data, to: directory.appendingPathComponent("transaction.json"))
            }
            catch {
                // Publication is the commit point. A writer can fail after an
                // atomic rename; never report rollback if that marker exists.
                guard (try? pendingTransaction()?.revision) == transaction.revision else { throw error }
            }
            // Once the synced marker exists the transaction is committed. Failure
            // to materialize is recoverable and must not be reported as rollback.
            revision = transaction.revision
            materializeCommitted(transaction)
        }
    }

    private func changes(previous: VoiceLibraryDocument, next: VoiceLibraryDocument) throws -> [Change] {
        var changes: [Change] = []
        if previous.examples != next.examples {
            try diff(
                previous.examples, next.examples, path: { "examples/\($0.id.uuidString).json" }, transform: metadata,
                changes: &changes)
            let old = Dictionary(uniqueKeysWithValues: previous.examples.map { ($0.id, $0) })
            let newIDs = Set(next.examples.map(\.id))
            for example in next.examples {
                let value = VoiceLibraryRepresentations(
                    embeddings: example.embeddings)
                let prior = old[example.id].map {
                    VoiceLibraryRepresentations(embeddings: $0.embeddings)
                }
                if prior != value && (!value.embeddings.isEmpty || prior != nil) {
                    changes.append(Change(path: representationPath(example.id), data: try encode(value)))
                }
            }
            for example in previous.examples where !newIDs.contains(example.id) {
                changes.append(Change(path: representationPath(example.id), data: nil))
            }
        }
        try diff(previous.jobs, next.jobs, path: { "jobs/\($0.id.uuidString).json" }, changes: &changes)
        try diff(
            previous.decisions, next.decisions,
            path: { "decisions/\($0.meetingID.uuidString)-\($0.speakerID.uuidString).json" }, changes: &changes)
        try diff(
            previous.deletedPersonIDs, next.deletedPersonIDs, path: { "deleted-people/\($0.uuidString).json" },
            changes: &changes)
        for index in 0..<max(previous.undo.count, next.undo.count) {
            let before = previous.undo.indices.contains(index) ? previous.undo[index] : nil
            let after = next.undo.indices.contains(index) ? next.undo[index] : nil
            if before != after {
                changes.append(Change(path: String(format: "undo/%03d.json", index), data: try after.map(encode)))
            }
        }
        return changes
    }

    func commit(previous: VoiceLibraryDocument, next: VoiceLibraryDocument, transaction: inout LibraryFileTransaction)
        throws
    {
        guard writable, !externalLockHeld, flock(lockDescriptor, LOCK_EX) == 0 else {
            throw ServiceError("Couldn’t lock the voice library.")
        }
        externalLockHeld = true
        externalOriginalRevision = revision
        externalNextRevision = nil
        do {
            try validateRevision()
            if let pending = try pendingTransaction() {
                try apply(pending)
                try refreshFileRevisions(pending.changes.map(\.path))
            }
            let changes = try changes(previous: previous, next: next)
            try validateFiles(changes)
            externalPaths = changes.map(\.path)
            let nextRevision = UUID()
            externalNextRevision = nextRevision
            for change in changes { try transaction.remember(recordURL(change.path)) }
            let header = directory.appendingPathComponent("state.json")
            try transaction.remember(header)
            try beforeCommit?()
            for change in changes {
                let url = try recordURL(change.path)
                if let data = change.data {
                    try atomicWrite(data, to: url)
                }
                else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            try atomicWrite(try encode(Header(revision: nextRevision)), to: header)
            revision = nextRevision
            try refreshFileRevisions(externalPaths)
        }
        catch {
            // The caller restores its journal before releasing this lock.
            throw error
        }
    }

    func reloadRevision(committed: Bool) throws {
        defer {
            if externalLockHeld {
                externalLockHeld = false
                flock(lockDescriptor, LOCK_UN)
            }
        }
        let current = try pendingTransaction()?.revision ?? readHeader()?.revision
        guard current == (committed ? externalNextRevision : externalOriginalRevision) else { throw changedError() }
        revision = current
        try refreshFileRevisions(externalPaths)
        externalPaths = []
    }

    private func metadata(_ value: VoiceExample) -> VoiceExample {
        var result = value
        result.embeddings = []
        return result
    }

    private func diff<T: Codable & Equatable>(
        _ previous: [T], _ next: [T], path: (T) -> String,
        transform: (T) -> T = { $0 }, changes: inout [Change]
    ) throws {
        guard previous != next else { return }
        var old: [String: T] = [:]
        for item in previous {
            guard old.updateValue(item, forKey: path(item)) == nil else {
                throw ServiceError("Duplicate voice-library records.")
            }
        }
        var seen = Set<String>()
        for item in next {
            let key = path(item)
            guard seen.insert(key).inserted else { throw ServiceError("Duplicate voice-library records.") }
            let value = transform(item)
            if old[key].map(transform) != value { changes.append(Change(path: key, data: try encode(value))) }
        }
        for key in old.keys where !seen.contains(key) { changes.append(Change(path: key, data: nil)) }
    }

    private func representationPath(_ id: UUID) -> String { "representations/\(id.uuidString).json" }

    private func readRecords<T: Decodable>(_ category: String, overlay: [String: Change], as: T.Type) throws -> [T] {
        let folder = directory.appendingPathComponent(category, isDirectory: true)
        var paths = Set<String>()
        if FileManager.default.fileExists(atPath: folder.path) {
            try rejectSymbolicLink(folder)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
                paths.insert(category + "/" + url.lastPathComponent)
            }
        }
        paths.formUnion(overlay.keys.filter { $0.hasPrefix(category + "/") })
        return try paths.sorted().compactMap { path in
            guard let value: T = try readRecord(path: path, overlay: overlay) else { return nil }
            let expected: String?
            if let example = value as? VoiceExample {
                expected = "examples/\(example.id.uuidString).json"
            }
            else if let job = value as? VoicePreparationJob {
                expected = "jobs/\(job.id.uuidString).json"
            }
            else if let decision = value as? VoiceSpeakerDecision {
                expected = "decisions/\(decision.meetingID.uuidString)-\(decision.speakerID.uuidString).json"
            }
            else if let id = value as? UUID {
                expected = "deleted-people/\(id.uuidString).json"
            }
            else {
                expected = nil
            }
            guard expected == nil || path == expected else {
                throw ServiceError("A voice-library record does not match its filename.")
            }
            return value
        }
    }

    private func readRecord<T: Decodable>(path: String, overlay: [String: Change]) throws -> T? {
        if let change = overlay[path] { return try change.data.map { try JSONDecoder().decode(T.self, from: $0) } }
        let url = try recordURL(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(url)
        return try JSONDecoder().decode(T.self, from: limitedData(url))
    }

    private func pendingTransaction() throws -> Transaction? {
        let url = directory.appendingPathComponent("transaction.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(url)
        let transaction = try JSONDecoder().decode(Transaction.self, from: limitedData(url))
        guard transaction.version == 1, Set(transaction.changes.map(\.path)).count == transaction.changes.count else {
            throw ServiceError("The voice-library transaction format is unsupported or invalid.")
        }
        let current = try readHeader()?.revision
        guard current == transaction.previousRevision || current == transaction.revision else { throw changedError() }
        for change in transaction.changes { _ = try recordURL(change.path) }
        return transaction
    }

    private func readHeader() throws -> Header? {
        let url = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(url)
        let header = try JSONDecoder().decode(Header.self, from: limitedData(url))
        guard header.version == 1 else {
            throw ServiceError("This voice library needs a newer version of Gday Meetings.")
        }
        return header
    }

    private func validateRevision() throws {
        let transaction = try pendingTransaction()
        let current = try transaction?.revision ?? readHeader()?.revision
        guard current == revision else { throw changedError() }
    }

    private func materializeCommitted(_ transaction: Transaction) {
        do {
            try apply(transaction)
            try refreshFileRevisions(transaction.changes.map(\.path))
            maintenanceWarning = nil
        }
        catch {
            maintenanceWarning =
                "The voice-library change is saved. Some record files will be recovered when the library reopens. \(error.localizedDescription)"
        }
    }

    private func apply(_ transaction: Transaction) throws {
        for change in transaction.changes {
            let url = try recordURL(change.path)
            if let data = change.data {
                try atomicWrite(data, to: url)
            }
            else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                try syncDirectory(url.deletingLastPathComponent())
            }
        }
        try atomicWrite(
            try encode(Header(revision: transaction.revision)), to: directory.appendingPathComponent("state.json"))
        let marker = directory.appendingPathComponent("transaction.json")
        try FileManager.default.removeItem(at: marker)
        try syncDirectory(directory)
    }

    private func captureFileRevisions() throws {
        var values: [String: String] = [:]
        for category in ["examples", "representations", "jobs", "decisions", "undo", "deleted-people"] {
            let folder = directory.appendingPathComponent(category)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            try rejectSymbolicLink(folder)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
                let path = category + "/" + url.lastPathComponent
                try rejectSymbolicLink(url)
                values[path] = VoiceLibraryStore.revision(url: url)
            }
        }
        fileRevisions = values
    }

    private func refreshFileRevisions(_ paths: [String]) throws {
        for path in paths { fileRevisions[path] = VoiceLibraryStore.revision(url: try recordURL(path)) }
    }

    private func validateFiles(_ changes: [Change]) throws {
        for change in changes {
            let url = try recordURL(change.path)
            guard VoiceLibraryStore.revision(url: url) == fileRevisions[change.path] else { throw changedError() }
        }
    }

    private func limitedData(_ url: URL) throws -> Data {
        let limit = 64 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw ServiceError("A voice-library record exceeds the supported size limit.")
        }
        return data
    }

    private func recordURL(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
            ["examples", "representations", "jobs", "decisions", "undo", "deleted-people"].contains(String(parts[0])),
            parts[1].hasSuffix(".json"), !parts[1].contains(".."), !parts[1].contains("\\")
        else { throw ServiceError("The voice library contains an invalid record path.") }
        let url = directory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            try rejectSymbolicLink(url.deletingLastPathComponent())
        }
        if FileManager.default.fileExists(atPath: url.path) { try rejectSymbolicLink(url) }
        return url
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ServiceError(
                "The voice library contains a symbolic link. Move its records into the data folder before editing.")
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: url.path) { try rejectSymbolicLink(url) }
        if let writeOverride {
            try writeOverride(data, url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }
        else {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".voice-record-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard
                FileManager.default.createFile(
                    atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw ServiceError("Couldn’t create a voice-library record.")
            }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw ServiceError("Couldn’t publish the voice-library record.")
            }
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw ServiceError("Couldn’t synchronize the voice-library folder.") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ServiceError("Couldn’t synchronize the voice-library folder.") }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        if lockDescriptor < 0 { return try body() }
        guard flock(lockDescriptor, writable ? LOCK_EX : LOCK_SH) == 0 else {
            throw ServiceError("Couldn’t lock the voice library.")
        }
        defer { flock(lockDescriptor, LOCK_UN) }
        return try body()
    }

    private func changedError() -> ServiceError {
        ServiceError("The voice library changed on disk. Reopen it before editing.")
    }
}
