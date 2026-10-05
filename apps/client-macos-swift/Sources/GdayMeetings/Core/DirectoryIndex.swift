import CSQLite
import Foundation

enum DirectoryKind: String, Sendable { case people, tags }

struct DirectoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isExcluded: Bool
    var meetingCount: Int = 0
}

struct DirectoryPage: Sendable {
    let entries: [DirectoryEntry]
    let total: Int
}

struct DirectoryWindow: Sendable {
    let page: DirectoryPage
    let hasPrevious: Bool
    let hasNext: Bool
}

struct DirectoryReveal: Equatable {
    let id = UUID()
    let targetID: UUID
}

/// A disposable list projection. Entity files and the store's conflict-checked
/// working records remain authoritative; a page is never passed to snapshot save.
final class DirectoryIndex: @unchecked Sendable {
    private let root: URL
    private let lock = NSRecursiveLock()
    private let connection: IndexDatabase.Connection
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let queue = DispatchQueue(label: "com.gdaymeetings.directory-index", qos: .utility)
    private let pendingLock = NSLock()
    private var pending: Set<URL> = []
    private var needsScan = false
    private var scheduled = false
    private var completion: (@Sendable (String?) -> Void)?

    init(root: URL, indexDirectory: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        connection = try IndexDatabase.open(at: indexDirectory.appendingPathComponent("index.db"))
        try connection.register(.library)
        try connection.register(.directory)
    }
    private func failure() -> Error { connection.failure() }
    private func execute(_ sql: String) throws { try connection.execute(sql) }
    private func prepare(_ sql: String) throws -> OpaquePointer { try connection.prepare(sql) }
    private func bind(_ value: String, at position: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, position, value, -1, transient)
    }
    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// Coalesces file events and app writes on one background queue.
    func enqueue(paths: [URL] = [], rebuild: Bool = false, completion: @escaping @Sendable (String?) -> Void) {
        pendingLock.lock()
        pending.formUnion(paths)
        needsScan = needsScan || rebuild
        self.completion = completion
        let start = !scheduled
        scheduled = true
        pendingLock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                pendingLock.lock()
                let paths = Array(pending)
                let scan = needsScan
                let callback = self.completion
                pending = []
                needsScan = false
                self.completion = nil
                if callback == nil { scheduled = false }
                pendingLock.unlock()
                guard let callback else { return }
                do {
                    try reconcile(paths: paths, rebuild: scan)
                    callback(nil)
                }
                catch { callback(error.localizedDescription) }
            }
        }
    }

    func reconcile(paths: [URL], rebuild: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        let state = try prepare("SELECT complete FROM state WHERE id=1")
        let incomplete = sqlite3_step(state) != SQLITE_ROW || sqlite3_column_int(state, 0) == 0
        sqlite3_finalize(state)
        var full = Set<DirectoryKind>()
        if rebuild || incomplete { full = [.people, .tags] }
        var changed: [DirectoryKind: Set<UUID>] = [:]
        for url in paths {
            let path = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(
                url.lastPathComponent
            ).standardizedFileURL
            for kind in [DirectoryKind.people, .tags] {
                let directory = root.appendingPathComponent(kind.rawValue)
                if path == root || path == directory {
                    full.insert(kind)
                }
                else if path.deletingLastPathComponent() == directory, path.pathExtension == "json",
                    let id = UUID(uuidString: path.deletingPathExtension().lastPathComponent)
                {
                    changed[kind, default: []].insert(id)
                }
            }
        }
        if full.isEmpty {
            let mutations = try changed.flatMap { kind, ids in try ids.map { try load(kind: kind, id: $0) } }
            guard !mutations.isEmpty else { return }
            try execute("BEGIN IMMEDIATE")
            do {
                for mutation in mutations { try apply(mutation) }
                try execute("COMMIT")
            }
            catch {
                try? execute("ROLLBACK")
                throw error
            }
            return
        }
        try connection.beginStaging(.directory, preservingRows: true)
        do {
            for kind in full {
                try execute("CREATE TEMP TABLE IF NOT EXISTS seen(id TEXT PRIMARY KEY); DELETE FROM seen;")
                let directory = root.appendingPathComponent(kind.rawValue)
                try validateDirectory(kind)
                if let files = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
                {
                    for case let file as URL in files where file.pathExtension == "json" {
                        guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                            throw MeetingError.message("A directory document has an invalid filename.")
                        }
                        try reconcile(kind: kind, id: id)
                        let seen = try prepare("INSERT OR IGNORE INTO seen VALUES(?)")
                        bind(id.uuidString, at: 1, to: seen)
                        defer { sqlite3_finalize(seen) }
                        try done(seen)
                    }
                }
                let remove = try prepare("DELETE FROM entities WHERE kind=? AND id NOT IN (SELECT id FROM seen)")
                defer { sqlite3_finalize(remove) }
                bind(kind.rawValue, at: 1, to: remove)
                try done(remove)
                if kind == .people { try execute("DELETE FROM person_tags WHERE person NOT IN (SELECT id FROM seen)") }
            }
            for (kind, ids) in changed where !full.contains(kind) {
                for id in ids { try reconcile(kind: kind, id: id) }
            }
            try execute("UPDATE state SET complete=1 WHERE id=1")
            try connection.publishStaging()
        }
        catch {
            connection.discardStaging()
            throw error
        }
    }
    private func validateDirectory(_ kind: DirectoryKind) throws {
        let directory = root.appendingPathComponent(kind.rawValue)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MeetingError.message("The \(kind.rawValue) directory must be a regular folder.")
        }
    }
    private struct Mutation {
        let kind: DirectoryKind
        let id: UUID
        let name: String?
        var excluded = false
        var tags: [UUID] = []
    }
    private func reconcile(kind: DirectoryKind, id: UUID) throws { try apply(load(kind: kind, id: id)) }
    private func load(kind: DirectoryKind, id: UUID) throws -> Mutation {
        try validateDirectory(kind)
        let url = root.appendingPathComponent(kind.rawValue).appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Mutation(kind: kind, id: id, name: nil)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MeetingError.message("A directory document is not a regular file.")
        }
        let bytes = try Data(contentsOf: url)
        if kind == .people {
            let person = try JSONDecoder().decode(Person.self, from: bytes)
            guard person.id == id else { throw MeetingError.message("The person ID does not match its filename.") }
            return Mutation(kind: kind, id: id, name: person.name, tags: person.tagIDs)
        }
        let tag = try JSONDecoder().decode(MeetingTag.self, from: bytes)
        guard tag.id == id else { throw MeetingError.message("The tag ID does not match its filename.") }
        return Mutation(kind: kind, id: id, name: tag.name, excluded: tag.isExcluded)
    }
    private func apply(_ mutation: Mutation) throws {
        let kind = mutation.kind
        let id = mutation.id
        if kind == .people { try replaceTags(person: id, tags: mutation.tags) }
        guard let name = mutation.name else {
            let remove = try prepare("DELETE FROM entities WHERE kind=? AND id=?")
            defer { sqlite3_finalize(remove) }
            bind(kind.rawValue, at: 1, to: remove)
            bind(id.uuidString, at: 2, to: remove)
            try done(remove)
            return
        }
        let insert = try prepare(
            "INSERT INTO entities VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET name=excluded.name,excluded=excluded.excluded"
        )
        defer { sqlite3_finalize(insert) }
        bind(kind.rawValue, at: 1, to: insert)
        bind(id.uuidString, at: 2, to: insert)
        bind(name, at: 3, to: insert)
        sqlite3_bind_int(insert, 4, mutation.excluded ? 1 : 0)
        try done(insert)
    }
    private func replaceTags(person: UUID, tags: [UUID]) throws {
        let remove = try prepare("DELETE FROM person_tags WHERE person=?")
        defer { sqlite3_finalize(remove) }
        bind(person.uuidString, at: 1, to: remove)
        try done(remove)
        let insert = try prepare("INSERT OR IGNORE INTO person_tags VALUES(?,?)")
        defer { sqlite3_finalize(insert) }
        for tag in tags {
            sqlite3_reset(insert)
            bind(person.uuidString, at: 1, to: insert)
            bind(tag.uuidString, at: 2, to: insert)
            try done(insert)
        }
    }
    private static let excluded =
        "EXISTS(SELECT 1 FROM person_tags p JOIN entities t ON t.kind='tags' AND t.id=p.tag WHERE p.person=e.id AND t.excluded=1)"

    func page(
        kind: DirectoryKind, query: String = "", showExcluded: Bool = false, after: DirectoryEntry? = nil,
        before: DirectoryEntry? = nil, limit: Int = 50, includingCursor: Bool = false
    ) throws -> DirectoryPage {
        lock.lock()
        defer { lock.unlock() }
        let filter =
            "e.kind=? AND GDAY_CONTAINS(e.name,?)"
            + (kind == .people && !showExcluded ? " AND NOT " + Self.excluded : "")
        let count = try prepare("SELECT count(*) FROM entities e WHERE " + filter)
        defer { sqlite3_finalize(count) }
        bind(kind.rawValue, at: 1, to: count)
        bind(query, at: 2, to: count)
        guard sqlite3_step(count) == SQLITE_ROW else { throw failure() }
        let total = Int(sqlite3_column_int64(count, 0))
        let cursor = after ?? before
        let condition =
            cursor == nil
            ? "" : " AND (e.name COLLATE GDAY_NAME,e.id) \(before == nil ? (includingCursor ? ">=" : ">") : "<") (?,?)"
        let order = before == nil ? "e.name COLLATE GDAY_NAME,e.id" : "e.name COLLATE GDAY_NAME DESC,e.id DESC"
        let excluded = kind == .people ? Self.excluded : "e.excluded"
        let statement = try prepare(
            "SELECT e.id,e.name," + excluded + " FROM entities e WHERE " + filter + condition + " ORDER BY " + order
                + " LIMIT ?")
        defer { sqlite3_finalize(statement) }
        bind(kind.rawValue, at: 1, to: statement)
        bind(query, at: 2, to: statement)
        if let cursor {
            bind(cursor.name, at: 3, to: statement)
            bind(cursor.id.uuidString, at: 4, to: statement)
        }
        sqlite3_bind_int(statement, cursor == nil ? 3 : 5, Int32(max(1, min(limit, 400))))
        var entries: [DirectoryEntry] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)) else { throw failure() }
            entries.append(
                DirectoryEntry(id: id, name: text(statement, 1), isExcluded: sqlite3_column_int(statement, 2) != 0))
        }
        if before != nil { entries.reverse() }
        if !entries.isEmpty {
            let counts = try prepare(
                "SELECT target,count(*) FROM relations WHERE kind=? AND target IN (SELECT value FROM json_each(?)) GROUP BY target"
            )
            defer { sqlite3_finalize(counts) }
            bind(kind == .people ? "person" : "tag", at: 1, to: counts)
            bind(
                String(decoding: try JSONEncoder().encode(entries.map { $0.id.uuidString }), as: UTF8.self), at: 2,
                to: counts)
            var values: [UUID: Int] = [:]
            while true {
                let status = sqlite3_step(counts)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                if let id = UUID(uuidString: text(counts, 0)) { values[id] = Int(sqlite3_column_int(counts, 1)) }
            }
            for position in entries.indices { entries[position].meetingCount = values[entries[position].id] ?? 0 }
        }
        return DirectoryPage(entries: entries, total: total)
    }
    /// Seek directly to an action target; ordinary scrolling never invokes this.
    func window(kind: DirectoryKind, id: UUID, query: String, showExcluded: Bool, expectedName: String? = nil) throws
        -> DirectoryWindow?
    {
        lock.lock()
        defer { lock.unlock() }
        let excluded = kind == .people ? Self.excluded : "e.excluded"
        let statement = try prepare(
            "SELECT e.name," + excluded + " FROM entities e WHERE e.kind=? AND e.id=? AND GDAY_CONTAINS(e.name,?)")
        defer { sqlite3_finalize(statement) }
        bind(kind.rawValue, at: 1, to: statement)
        bind(id.uuidString, at: 2, to: statement)
        bind(query, at: 3, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        let target = DirectoryEntry(id: id, name: text(statement, 0), isExcluded: sqlite3_column_int(statement, 1) != 0)
        guard kind != .people || showExcluded || !target.isExcluded else { return nil }
        if let expectedName, target.name != expectedName { return nil }
        let before = try page(kind: kind, query: query, showExcluded: showExcluded, before: target, limit: 25)
        let after = try page(
            kind: kind, query: query, showExcluded: showExcluded, after: target, limit: 25, includingCursor: true)
        return DirectoryWindow(
            page: DirectoryPage(entries: before.entries + after.entries, total: after.total),
            hasPrevious: before.entries.count == 25, hasNext: after.entries.count == 25)
    }

    func exactPerson(name: String) throws -> UUID? {
        try exact(kind: .people, name: name)
    }
    func exactTag(name: String) throws -> UUID? {
        try exact(kind: .tags, name: name)
    }
    private func exact(kind: DirectoryKind, name: String) throws -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            "SELECT id FROM entities WHERE kind=? AND GDAY_EQUAL(name,?) ORDER BY id LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(kind.rawValue, at: 1, to: statement)
        bind(name, at: 2, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        return UUID(uuidString: text(statement, 0))
    }
}
