import CSQLite
import Foundation

/// Disposable derived records. The connection is serialized; callers can rebuild on a background queue.
final class LibraryIndex: @unchecked Sendable {
    let directory: URL
    let indexDirectory: URL
    private(set) var lastRebuildErrorCount = 0
    private(set) var lastCommittedCount: Int?
    private(set) var recoveredCorruptIndex = false
    private(set) var requiresRebuild = false
    private var statements: [String: OpaquePointer] = [:]
    private var lastPageSQL: String?
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL, indexDirectory: URL? = nil) throws {
        self.directory = directory
        let indexDirectory = indexDirectory ?? directory
        self.indexDirectory = indexDirectory
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        guard
            sqlite3_open_v2(
                indexDirectory.appendingPathComponent("index.db").path, &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else {
            throw MeetingError.message("Couldn’t open the library index.")
        }
        sqlite3_busy_timeout(database, 5000)
        do { try createSchema() }
        catch {
            let status = sqlite3_errcode(database)
            guard status == SQLITE_CORRUPT || status == SQLITE_NOTADB else { throw error }
            for statement in statements.values { sqlite3_finalize(statement) }
            statements.removeAll()
            sqlite3_close(database)
            database = nil
            let suffix = ".corrupt-" + UUID().uuidString
            for name in ["index.db", "index.db-wal", "index.db-shm"] {
                let file = indexDirectory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.moveItem(at: file, to: indexDirectory.appendingPathComponent(name + suffix))
                }
            }
            guard
                sqlite3_open_v2(
                    indexDirectory.appendingPathComponent("index.db").path, &database,
                    SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
            else { throw failure() }
            sqlite3_busy_timeout(database, 5000)
            try createSchema()
            recoveredCorruptIndex = true
            requiresRebuild = true
        }
    }
    private func createSchema() throws {
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-8192;")
        let version = try statement("PRAGMA user_version")
        guard sqlite3_step(version) == SQLITE_ROW else {
            release(version)
            throw failure()
        }
        let previous = sqlite3_column_int(version, 0)
        release(version)
        if previous != 2 {
            let exists = try statement("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='meetings'")
            if sqlite3_step(exists) == SQLITE_ROW { requiresRebuild = sqlite3_column_int(exists, 0) > 0 }
            release(exists)
            try execute(
                "BEGIN IMMEDIATE; DROP TABLE IF EXISTS meetings; DROP TABLE IF EXISTS relations; DROP TABLE IF EXISTS search; DROP TABLE IF EXISTS index_state; COMMIT;"
            )
            try execute(
                "CREATE TABLE IF NOT EXISTS meetings(id TEXT PRIMARY KEY, created REAL NOT NULL, sortTime REAL NOT NULL, title TEXT NOT NULL, metadata BLOB NOT NULL); CREATE INDEX IF NOT EXISTS meeting_seek ON meetings(sortTime,id); CREATE TABLE IF NOT EXISTS relations(meeting TEXT NOT NULL,kind TEXT NOT NULL,target TEXT NOT NULL,sortTime REAL NOT NULL,PRIMARY KEY(meeting,kind,target)); CREATE INDEX IF NOT EXISTS relation_seek ON relations(kind,target,sortTime,meeting); CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, text); CREATE TABLE IF NOT EXISTS index_state(id INTEGER PRIMARY KEY CHECK(id=1),complete INTEGER NOT NULL); INSERT OR IGNORE INTO index_state VALUES(1,0); PRAGMA user_version=2;"
            )
        }
        let completion = try statement("SELECT complete FROM index_state WHERE id=1")
        defer { release(completion) }
        guard sqlite3_step(completion) == SQLITE_ROW else { throw failure() }
        requiresRebuild = sqlite3_column_int(completion, 0) == 0
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(database)
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> Error {
        MeetingError.message("Couldn’t update the library index: \(String(cString: sqlite3_errmsg(database)))")
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = statements.removeValue(forKey: sql) { return cached }
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
        return value
    }
    private func release(_ statement: OpaquePointer) {
        let sql = String(cString: sqlite3_sql(statement))
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        if let old = statements.updateValue(statement, forKey: sql) { sqlite3_finalize(old) }
    }
    private func bind(_ text: String, _ position: Int32, _ stmt: OpaquePointer) {
        sqlite3_bind_text(stmt, position, text, -1, transient)
    }
    func markEmptyLibraryComplete() throws {
        lock.lock()
        defer { lock.unlock() }
        guard try count() == 0 else { return }
        try execute("UPDATE index_state SET complete=1 WHERE id=1")
        requiresRebuild = false
    }
    func upsert(_ entry: MeetingListEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONEncoder().encode(entry)
        let stmt = try statement(
            "INSERT INTO meetings(id,created,title,metadata,sortTime) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET created=excluded.created,title=excluded.title,metadata=excluded.metadata,sortTime=excluded.sortTime"
        )
        defer { release(stmt) }
        bind(entry.id.uuidString, 1, stmt)
        sqlite3_bind_double(stmt, 2, entry.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, -entry.createdAt.timeIntervalSince1970)
        bind(entry.title, 3, stmt)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        let delete = try statement("DELETE FROM relations WHERE meeting=?")
        bind(entry.id.uuidString, 1, delete)
        defer { release(delete) }
        guard sqlite3_step(delete) == SQLITE_DONE else { throw failure() }
        let searchDelete = try statement("DELETE FROM search WHERE rowid=(SELECT rowid FROM meetings WHERE id=?)")
        bind(entry.id.uuidString, 1, searchDelete)
        defer { release(searchDelete) }
        guard sqlite3_step(searchDelete) == SQLITE_DONE else { throw failure() }
        let content = try MeetingFolderStorage.searchText(id: entry.id, directory: directory)
        let searchInsert = try statement(
            "INSERT INTO search(rowid,id,text) VALUES((SELECT rowid FROM meetings WHERE id=?),?,?)")
        defer { release(searchInsert) }
        bind(entry.id.uuidString, 1, searchInsert)
        bind(entry.id.uuidString, 2, searchInsert)
        bind(entry.title + " " + entry.summary + " " + content, 3, searchInsert)
        guard sqlite3_step(searchInsert) == SQLITE_DONE else { throw failure() }
        let relation = try statement("INSERT OR IGNORE INTO relations VALUES(?,?,?,?)")
        defer { release(relation) }
        for (kind, ids) in [("person", entry.personIDs), ("tag", entry.tagIDs)] {
            for id in ids {
                sqlite3_reset(relation)
                bind(entry.id.uuidString, 1, relation)
                bind(kind, 2, relation)
                bind(id.uuidString, 3, relation)
                sqlite3_bind_double(relation, 4, -entry.createdAt.timeIntervalSince1970)
                guard sqlite3_step(relation) == SQLITE_DONE else { throw failure() }
            }
        }
    }
    func remove(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let search = try statement("DELETE FROM search WHERE rowid=(SELECT rowid FROM meetings WHERE id=?)")
        defer { release(search) }
        bind(id.uuidString, 1, search)
        guard sqlite3_step(search) == SQLITE_DONE else { throw failure() }
        for table in ["meetings", "relations"] {
            let stmt = try statement("DELETE FROM \(table) WHERE \(table == "relations" ? "meeting" : "id")=?")
            defer { release(stmt) }
            bind(id.uuidString, 1, stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
    }
    func entry(id: UUID) throws -> MeetingListEntry? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try statement("SELECT metadata FROM meetings WHERE id=?")
        defer { release(stmt) }
        bind(id.uuidString, 1, stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? try decode(stmt) : nil
    }
    private func decode(_ stmt: OpaquePointer) throws -> MeetingListEntry {
        let count = Int(sqlite3_column_bytes(stmt, 0))
        return try JSONDecoder().decode(
            MeetingListEntry.self, from: Data(bytes: sqlite3_column_blob(stmt, 0)!, count: count))
    }
    func pendingTranscriptions() throws -> [PrivacyContext.PendingTranscription] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try statement(
            "SELECT metadata FROM meetings WHERE json_extract(metadata,'$.pendingProviderID') IS NOT NULL")
        defer { release(stmt) }
        var result: [PrivacyContext.PendingTranscription] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entry = try decode(stmt)
            if let providerID = entry.pendingProviderID {
                result.append(.init(providerID: providerID, uploadProviderID: entry.pendingUploadProviderID))
            }
        }
        return result
    }
    private static let exclusionClause =
        "NOT EXISTS (SELECT 1 FROM relations hidden WHERE hidden.meeting=m.id AND hidden.kind='tag' AND hidden.target IN (SELECT value FROM json_each(?)))"

    private func encodedTagIDs(_ ids: Set<UUID>) throws -> String {
        String(decoding: try JSONEncoder().encode(ids.map(\.uuidString).sorted()), as: UTF8.self)
    }

    func count(personID: UUID? = nil, tagID: UUID? = nil, excludingTagIDs: Set<UUID> = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let target = personID ?? tagID
        let sql: String
        if excludingTagIDs.isEmpty {
            sql =
                target == nil
                ? "SELECT count(*) FROM meetings" : "SELECT count(*) FROM relations WHERE kind=? AND target=?"
        }
        else {
            sql =
                "SELECT count(*) FROM meetings m WHERE "
                + (target == nil ? "" : "m.id IN (SELECT meeting FROM relations WHERE kind=? AND target=?) AND ")
                + Self.exclusionClause
        }
        let stmt = try statement(sql)
        defer { release(stmt) }
        if let target {
            bind(personID == nil ? "tag" : "person", 1, stmt)
            bind(target.uuidString, 2, stmt)
        }
        if !excludingTagIDs.isEmpty { bind(try encodedTagIDs(excludingTagIDs), target == nil ? 1 : 3, stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    func page(
        after: MeetingListEntry? = nil, before: MeetingListEntry? = nil, limit: Int = 20, query: String = "",
        personID: UUID? = nil, tagID: UUID? = nil, excludingTagIDs: Set<UUID> = []
    ) throws -> [MeetingListEntry] {
        lock.lock()
        defer { lock.unlock() }
        let related = personID != nil || tagID != nil
        let order = related ? "r.sortTime,r.meeting" : "m.sortTime,m.id"
        var clauses: [String] = []
        if related { clauses += ["r.kind=?", "r.target=?"] }
        if after != nil || before != nil { clauses.append("(\(order)) \(before == nil ? ">" : "<") (?,?)") }
        if !query.isEmpty { clauses.append("m.id IN (SELECT id FROM search WHERE search MATCH ?)") }
        if !excludingTagIDs.isEmpty { clauses.append(Self.exclusionClause) }
        let from =
            related
            ? "relations r INDEXED BY relation_seek CROSS JOIN meetings m ON m.id=r.meeting"
            : "meetings m INDEXED BY meeting_seek"
        let sorting = before == nil ? order : (related ? "r.sortTime DESC,r.meeting DESC" : "m.sortTime DESC,m.id DESC")
        let stmt = try statement(
            "SELECT m.metadata FROM " + from + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "))
                + " ORDER BY " + sorting + " LIMIT ?")
        lastPageSQL = String(cString: sqlite3_sql(stmt))
        defer { release(stmt) }
        var position: Int32 = 1
        if let target = personID ?? tagID {
            bind(personID == nil ? "tag" : "person", position, stmt)
            position += 1
            bind(target.uuidString, position, stmt)
            position += 1
        }
        if let cursor = after ?? before {
            sqlite3_bind_double(stmt, position, -cursor.createdAt.timeIntervalSince1970)
            position += 1
            bind(cursor.id.uuidString, position, stmt)
            position += 1
        }
        if !query.isEmpty {
            bind("\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\"", position, stmt)
            position += 1
        }
        if !excludingTagIDs.isEmpty {
            bind(try encodedTagIDs(excludingTagIDs), position, stmt)
            position += 1
        }
        sqlite3_bind_int(stmt, position, Int32(limit))
        var result: [MeetingListEntry] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return before == nil ? result : result.reversed() }
            guard status == SQLITE_ROW else { throw failure() }
            result.append(try decode(stmt))
        }
    }
    /// Inspect the actual most recent paging query, including the forced ordering indexes.
    func pageQueryPlan() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let lastPageSQL else { return [] }
        let stmt = try statement("EXPLAIN QUERY PLAN " + lastPageSQL)
        defer { release(stmt) }
        var details: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            details.append(String(cString: sqlite3_column_text(stmt, 3)))
        }
        return details
    }
    func rebuild(progress: @Sendable (Int) -> Void = { _ in }) throws {
        lock.lock()
        defer { lock.unlock() }
        lastRebuildErrorCount = 0
        lastCommittedCount = nil
        let publishBatches = try count() == 0
        try execute(
            "BEGIN IMMEDIATE; CREATE TEMP TABLE IF NOT EXISTS rebuild_seen(id TEXT PRIMARY KEY); DELETE FROM rebuild_seen;"
        )
        do {
            var count = 0
            let root = directory.appendingPathComponent("meetings")
            if let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            {
                while true {
                    let hasNext = try autoreleasepool { () throws -> Bool in
                        guard let folder = enumerator.nextObject() as? URL else { return false }
                        let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                        guard values.isSymbolicLink != true, values.isDirectory == true,
                            let id = MeetingIdentity.parse(folder.lastPathComponent)
                        else { return true }
                        let url = folder.appendingPathComponent("metadata.json")
                        let seen = try statement("INSERT OR IGNORE INTO rebuild_seen VALUES(?)")
                        bind(id.uuidString, 1, seen)
                        guard sqlite3_step(seen) == SQLITE_DONE else {
                            release(seen)
                            throw failure()
                        }
                        release(seen)
                        try execute("SAVEPOINT rebuild_row")
                        do {
                            let entry = try JSONDecoder().decode(MeetingListEntry.self, from: Data(contentsOf: url))
                            guard entry.id == id else {
                                throw MeetingError.message("Meeting ID differs from its folder.")
                            }
                            try upsert(entry)
                            try execute("RELEASE rebuild_row")
                        }
                        catch {
                            try execute("ROLLBACK TO rebuild_row; RELEASE rebuild_row")
                            lastRebuildErrorCount += 1
                        }
                        count += 1
                        if count % 500 == 0 {
                            if publishBatches {
                                try execute("COMMIT; BEGIN IMMEDIATE")
                                lastCommittedCount = try self.count()
                            }
                            progress(count)
                        }
                        return true
                    }
                    if !hasNext { break }
                }
            }
            try execute(
                "DELETE FROM meetings WHERE id NOT IN (SELECT id FROM rebuild_seen); DELETE FROM relations WHERE meeting NOT IN (SELECT id FROM rebuild_seen); DELETE FROM search WHERE id NOT IN (SELECT id FROM rebuild_seen); UPDATE index_state SET complete=1 WHERE id=1; COMMIT"
            )
            requiresRebuild = false
            lastCommittedCount = try self.count()
            progress(count)
        }
        catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    func reconcile(paths: [URL]) throws {
        for path in paths {
            var folder = path
            while folder.path.hasPrefix(directory.path), folder != directory {
                if let id = MeetingIdentity.parse(folder.lastPathComponent),
                    MeetingFolderStorage.folder(id: id, directory: directory).standardizedFileURL.path
                        == folder.standardizedFileURL.path
                {
                    let metadata = folder.appendingPathComponent("metadata.json")
                    if FileManager.default.fileExists(atPath: metadata.path) {
                        let entry = try JSONDecoder().decode(MeetingListEntry.self, from: Data(contentsOf: metadata))
                        guard entry.id == id else {
                            throw MeetingError.message("Meeting ID differs from its folder.")
                        }
                        try upsert(entry)
                    }
                    else {
                        try remove(id: id)
                    }
                    break
                }
                folder.deleteLastPathComponent()
            }
        }
    }
}
