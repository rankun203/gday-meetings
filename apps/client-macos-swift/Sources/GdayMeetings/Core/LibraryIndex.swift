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
    private var lastPageSQL: String?
    private let locationConnection: IndexDatabase.Connection
    private let locationLock = NSLock()
    private let connection: IndexDatabase.Connection
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL, indexDirectory: URL? = nil) throws {
        self.directory = directory
        let indexDirectory = indexDirectory ?? directory
        self.indexDirectory = indexDirectory
        connection = try IndexDatabase.open(at: indexDirectory.appendingPathComponent("index.db"))
        try connection.register(.library)
        locationConnection = try IndexDatabase.open(at: indexDirectory.appendingPathComponent("index.db"))
        recoveredCorruptIndex = connection.recoveredCorruption
        let completion = try statement("SELECT complete FROM index_state WHERE id=1")
        defer { release(completion) }
        guard sqlite3_step(completion) == SQLITE_ROW else { throw failure() }
        requiresRebuild = sqlite3_column_int(completion, 0) == 0
        MeetingFolderLocation.registerIndex(self)
    }
    private func execute(_ sql: String) throws { try connection.execute(sql) }
    private func failure() -> Error { connection.failure() }
    private func statement(_ sql: String) throws -> OpaquePointer { try connection.prepare(sql) }
    private func release(_ statement: OpaquePointer) { connection.release(statement) }
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
    func folderName(id: UUID) throws -> String? {
        // Source resolution must not wait for a long-running rebuild or see its TEMP tables.
        locationLock.lock()
        defer { locationLock.unlock() }
        let query = try locationConnection.prepare("SELECT name FROM main.meeting_folders WHERE id=?")
        defer { locationConnection.release(query) }
        bind(id.uuidString, 1, query)
        let result = sqlite3_step(query)
        guard result == SQLITE_ROW else {
            guard result == SQLITE_DONE else { throw locationConnection.failure() }
            return nil
        }
        return String(cString: sqlite3_column_text(query, 0))
    }

    func quarantine(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("SAVEPOINT quarantine_row")
        do {
            try remove(id: id)
            let query = try statement("INSERT INTO meeting_folders VALUES(?,'') ON CONFLICT(id) DO UPDATE SET name=''")
            defer { release(query) }
            bind(id.uuidString, 1, query)
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
            MeetingFolderLocation.block(id: id, directory: directory)
            try execute("RELEASE quarantine_row")
        }
        catch {
            try execute("ROLLBACK TO quarantine_row; RELEASE quarantine_row")
            MeetingFolderLocation.forget(id: id, directory: directory)
            throw error
        }
    }

    func upsert(
        _ entry: MeetingListEntry, folder suppliedFolder: URL? = nil, confirmedUnique: Bool = false,
        refreshSearch: Bool = true
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let folder =
            try suppliedFolder
            ?? MeetingFolderLocation.resolve(id: entry.id, directory: directory, date: entry.createdAt)
        try MeetingFolderLocation.validate(folder, directory: directory)
        if !confirmedUnique, let previous = try folderName(id: entry.id) {
            if previous.isEmpty { throw MeetingFolderLocation.AccessError.duplicate }
            if previous != folder.lastPathComponent,
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("meetings").appendingPathComponent(previous).path)
            {
                try quarantine(id: entry.id)
                throw MeetingFolderLocation.AccessError.duplicate
            }
        }
        else if !confirmedUnique, suppliedFolder != nil,
            try MeetingFolderLocation.candidates(id: entry.id, directory: directory).count > 1
        {
            try quarantine(id: entry.id)
            throw MeetingFolderLocation.AccessError.duplicate
        }
        let passages =
            refreshSearch ? try MeetingFolderStorage.searchPassages(folder: folder, directory: directory) : []
        try execute("SAVEPOINT upsert_row")
        do {
            let location = try statement(
                "INSERT INTO meeting_folders VALUES(?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name")
            defer { release(location) }
            bind(entry.id.uuidString, 1, location)
            bind(folder.lastPathComponent, 2, location)
            guard sqlite3_step(location) == SQLITE_DONE else { throw failure() }
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
            // UI saves update catalog metadata immediately. The existing reconciliation
            // worker refreshes passage content from the committed files off the main thread.
            if refreshSearch {
                let passageDelete = try statement(
                    "DELETE FROM search_passages WHERE rowid IN (SELECT id FROM search_locations WHERE meeting=?)")
                defer { release(passageDelete) }
                bind(entry.id.uuidString, 1, passageDelete)
                guard sqlite3_step(passageDelete) == SQLITE_DONE else { throw failure() }
                let revision = UUID().uuidString
                let locationInsert = try statement(
                    "INSERT INTO search_locations(meeting,source,revision) VALUES(?,?,?) ON CONFLICT(meeting,source) DO UPDATE SET revision=excluded.revision RETURNING id"
                )
                defer { release(locationInsert) }
                let passageInsert = try statement(
                    "INSERT INTO search_passages(meeting,kind,segment,start,text,rowid) VALUES(?,?,?,?,?,?)")
                defer { release(passageInsert) }
                for passage in [LibrarySearchPassage(kind: .title, text: entry.title)] + passages {
                    sqlite3_reset(locationInsert)
                    bind(entry.id.uuidString, 1, locationInsert)
                    bind(passage.kind.rawValue + (passage.segmentID?.uuidString ?? ""), 2, locationInsert)
                    bind(revision, 3, locationInsert)
                    guard sqlite3_step(locationInsert) == SQLITE_ROW else { throw failure() }
                    let passageID = sqlite3_column_int64(locationInsert, 0)
                    guard sqlite3_step(locationInsert) == SQLITE_DONE else { throw failure() }
                    sqlite3_reset(passageInsert)
                    sqlite3_clear_bindings(passageInsert)
                    bind(entry.id.uuidString, 1, passageInsert)
                    bind(passage.kind.rawValue, 2, passageInsert)
                    bind(passage.segmentID?.uuidString ?? "", 3, passageInsert)
                    if let start = passage.start { sqlite3_bind_double(passageInsert, 4, start) }
                    bind(passage.text, 5, passageInsert)
                    sqlite3_bind_int64(passageInsert, 6, passageID)
                    guard sqlite3_step(passageInsert) == SQLITE_DONE else { throw failure() }
                }
                let locationDelete = try statement("DELETE FROM search_locations WHERE meeting=? AND revision!=?")
                defer { release(locationDelete) }
                bind(entry.id.uuidString, 1, locationDelete)
                bind(revision, 2, locationDelete)
                guard sqlite3_step(locationDelete) == SQLITE_DONE else { throw failure() }
            }
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
            try execute("RELEASE upsert_row")
            if !connection.isStaging {
                MeetingFolderLocation.remember(folder, id: entry.id, directory: directory)
            }
        }
        catch {
            try execute("ROLLBACK TO upsert_row; RELEASE upsert_row")
            MeetingFolderLocation.forget(id: entry.id, directory: directory)
            throw error
        }
    }

    func remove(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("SAVEPOINT remove_row")
        do {
            MeetingFolderLocation.forget(id: id, directory: directory)
            let passages = try statement(
                "DELETE FROM search_passages WHERE rowid IN (SELECT id FROM search_locations WHERE meeting=?)")
            defer { release(passages) }
            bind(id.uuidString, 1, passages)
            guard sqlite3_step(passages) == SQLITE_DONE else { throw failure() }
            let locations = try statement("DELETE FROM search_locations WHERE meeting=?")
            defer { release(locations) }
            bind(id.uuidString, 1, locations)
            guard sqlite3_step(locations) == SQLITE_DONE else { throw failure() }
            for table in ["meetings", "relations", "meeting_folders"] {
                let stmt = try statement("DELETE FROM \(table) WHERE \(table == "relations" ? "meeting" : "id")=?")
                defer { release(stmt) }
                bind(id.uuidString, 1, stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            }
            try execute("RELEASE remove_row")
        }
        catch {
            try execute("ROLLBACK TO remove_row; RELEASE remove_row")
            MeetingFolderLocation.forget(id: id, directory: directory)
            throw error
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

    func count(personID: UUID? = nil, tagID: UUID? = nil, excludingTagIDs: Set<UUID> = [], query: String = "") throws
        -> Int
    {
        lock.lock()
        defer { lock.unlock() }
        let target = personID ?? tagID
        let sql: String
        if excludingTagIDs.isEmpty && query.isEmpty {
            sql =
                target == nil
                ? "SELECT count(*) FROM meetings" : "SELECT count(*) FROM relations WHERE kind=? AND target=?"
        }
        else {
            var clauses: [String] = []
            if target != nil { clauses.append("m.id IN (SELECT meeting FROM relations WHERE kind=? AND target=?)") }
            if !excludingTagIDs.isEmpty { clauses.append(Self.exclusionClause) }
            if !query.isEmpty {
                clauses.append("m.id IN (SELECT meeting FROM search_passages WHERE search_passages MATCH ?)")
            }
            sql = "SELECT count(*) FROM meetings m WHERE " + clauses.joined(separator: " AND ")
        }
        let stmt = try statement(sql)
        defer { release(stmt) }
        if let target {
            bind(personID == nil ? "tag" : "person", 1, stmt)
            bind(target.uuidString, 2, stmt)
        }
        if !excludingTagIDs.isEmpty { bind(try encodedTagIDs(excludingTagIDs), target == nil ? 1 : 3, stmt) }
        if !query.isEmpty {
            let position: Int32 = (target == nil ? 1 : 3) + (excludingTagIDs.isEmpty ? 0 : 1)
            bind("\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\"", position, stmt)
        }
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
        if !query.isEmpty {
            clauses.append("m.id IN (SELECT meeting FROM search_passages WHERE search_passages MATCH ?)")
        }
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
    /// Search only the derived index. Passage IDs and snippets need no transcript reads.
    func searchPage(
        query: String, after: Int64 = 0, limit: Int = 50, excludingTagIDs: Set<UUID> = [], ranked: Bool = false
    ) throws
        -> LibrarySearchPage
    {
        lock.lock()
        defer { lock.unlock() }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return LibrarySearchPage(results: [], total: 0) }
        let expression = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let exclusion = excludingTagIDs.isEmpty ? "" : " AND " + Self.exclusionClause
        let count = try statement(
            "SELECT " + (ranked ? "count(DISTINCT m.id)" : "count(*)")
                + " FROM search_passages p JOIN meetings m ON m.id=p.meeting WHERE search_passages MATCH ?"
                + exclusion)
        defer { release(count) }
        bind(expression, 1, count)
        if !excludingTagIDs.isEmpty { bind(try encodedTagIDs(excludingTagIDs), 2, count) }
        guard sqlite3_step(count) == SQLITE_ROW else { throw failure() }
        let total = Int(sqlite3_column_int64(count, 0))
        let stmt = try statement(
            "SELECT p.rowid,m.id,m.title,m.created,p.kind,p.segment,p.start,snippet(search_passages,4,'','','…',32) FROM search_passages p JOIN meetings m ON m.id=p.meeting WHERE search_passages MATCH ?"
                + (ranked ? "" : " AND p.rowid>?")
                + exclusion + (ranked ? " ORDER BY bm25(search_passages),p.rowid" : " ORDER BY p.rowid LIMIT ?")
        )
        defer { release(stmt) }
        bind(expression, 1, stmt)
        var position: Int32 = 2
        if !ranked {
            sqlite3_bind_int64(stmt, position, after)
            position += 1
        }
        if !excludingTagIDs.isEmpty {
            bind(try encodedTagIDs(excludingTagIDs), position, stmt)
            position += 1
        }
        let pageSize = max(1, min(limit, 100))
        if !ranked { sqlite3_bind_int(stmt, position, Int32(pageSize)) }
        func text(_ column: Int32) -> String {
            guard let value = sqlite3_column_text(stmt, column) else { return "" }
            return String(cString: value)
        }
        var results: [LibrarySearchResult] = []
        var rankedMeetings: Set<UUID> = []
        while true {
            if results.count == pageSize { return LibrarySearchPage(results: results, total: total) }
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return LibrarySearchPage(results: results, total: total) }
            guard status == SQLITE_ROW, let meetingID = UUID(uuidString: text(1)),
                let kind = LibrarySearchKind(rawValue: text(4))
            else { throw failure() }
            if ranked {
                // One candidate per meeting keeps long transcripts from crowding
                // every other meeting out of the fusion candidate set.
                guard rankedMeetings.insert(meetingID).inserted,
                    Int64(rankedMeetings.count) > max(0, after)
                else { continue }
            }
            results.append(
                LibrarySearchResult(
                    id: sqlite3_column_int64(stmt, 0), meetingID: meetingID, title: text(2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)), kind: kind,
                    segmentID: UUID(uuidString: text(5)),
                    start: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6),
                    excerpt: text(7)))
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
        if !publishBatches { try connection.beginStaging(.library, preservingRows: true) }
        try execute(
            "CREATE TEMP TABLE IF NOT EXISTS rebuild_seen(id TEXT PRIMARY KEY); DELETE FROM rebuild_seen; CREATE TEMP TABLE IF NOT EXISTS rebuild_folder_counts(id TEXT PRIMARY KEY, occurrences INTEGER NOT NULL); DELETE FROM rebuild_folder_counts;"
        )
        do {
            var count = 0
            let root = directory.appendingPathComponent("meetings")
            try MeetingFolderLocation.validate(root.appendingPathComponent("check"), directory: directory)
            // Count identities before publishing any metadata, independent of enumeration order.
            if let scan = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            {
                for case let folder as URL in scan {
                    let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true,
                        let id = MeetingFolderLocation.identity(folder.lastPathComponent)
                    else { continue }
                    let insert = try statement(
                        "INSERT INTO rebuild_folder_counts VALUES(?,1) ON CONFLICT(id) DO UPDATE SET occurrences=occurrences+1"
                    )
                    bind(id.uuidString, 1, insert)
                    let result = sqlite3_step(insert)
                    release(insert)
                    guard result == SQLITE_DONE else { throw failure() }
                }
            }
            if let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            {
                while true {
                    let hasNext = try autoreleasepool { () throws -> Bool in
                        guard let folder = enumerator.nextObject() as? URL else { return false }
                        let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                        guard values.isSymbolicLink != true, values.isDirectory == true,
                            let id = MeetingFolderLocation.identity(folder.lastPathComponent)
                        else { return true }
                        let url = folder.appendingPathComponent("metadata.json")
                        let seen = try statement("INSERT OR IGNORE INTO rebuild_seen VALUES(?)")
                        bind(id.uuidString, 1, seen)
                        guard sqlite3_step(seen) == SQLITE_DONE else {
                            release(seen)
                            throw failure()
                        }
                        release(seen)
                        let occurrences = try statement("SELECT occurrences FROM rebuild_folder_counts WHERE id=?")
                        bind(id.uuidString, 1, occurrences)
                        let duplicate =
                            sqlite3_step(occurrences) == SQLITE_ROW && sqlite3_column_int(occurrences, 0) > 1
                        release(occurrences)
                        if duplicate {
                            try quarantine(id: id)
                            lastRebuildErrorCount += 1
                            return true
                        }
                        do {
                            let entry = try JSONDecoder().decode(MeetingListEntry.self, from: Data(contentsOf: url))
                            guard entry.id == id else {
                                throw MeetingError.message("Meeting ID differs from its folder.")
                            }
                            try upsert(entry, folder: folder, confirmedUnique: true)
                        }
                        catch {
                            lastRebuildErrorCount += 1
                        }
                        count += 1
                        if count % 500 == 0 {
                            if publishBatches {
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
                "DELETE FROM meetings WHERE id NOT IN (SELECT id FROM rebuild_seen); DELETE FROM meeting_folders WHERE id NOT IN (SELECT id FROM rebuild_seen); DELETE FROM relations WHERE meeting NOT IN (SELECT id FROM rebuild_seen); DELETE FROM search_passages WHERE rowid IN (SELECT id FROM search_locations WHERE meeting NOT IN (SELECT id FROM rebuild_seen)); DELETE FROM search_locations WHERE meeting NOT IN (SELECT id FROM rebuild_seen); UPDATE index_state SET complete=1 WHERE id=1"
            )
            if !publishBatches { try connection.publishStaging() }
            requiresRebuild = false
            lastCommittedCount = try self.count()
            progress(count)
        }
        catch {
            connection.discardStaging()
            throw error
        }
    }
    /// A missing authoritative document invalidates its disposable catalog row.
    /// Recheck the location on disk so a renamed folder is not mistaken for deletion.
    func reconcileMissingMeeting(id: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = try directory.resourceValues(forKeys: [.isDirectoryKey])
        _ = try directory.appendingPathComponent("meetings").resourceValues(forKeys: [.isDirectoryKey])
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".document-transaction").path)
        else { return false }
        let folder = try MeetingFolderLocation.resolve(id: id, directory: directory)
        let metadata = folder.appendingPathComponent("metadata.json")
        do {
            _ = try metadata.resourceValues(forKeys: [.isRegularFileKey])
            return false
        }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            try remove(id: id)
            return true
        }
    }

    func reconcile(paths: [URL]) throws {
        lock.lock()
        defer { lock.unlock() }
        // File URL standardization rewrites existing /private paths but not deleted paths.
        // Normalize syntax only so removal events retain the watcher’s physical root spelling.
        let root = directory.standardized
        let meetings = root.appendingPathComponent("meetings").standardized
        let normalized = paths.map(\.standardized)
        // A coalesced ancestor event may be the only notice of removed meeting folders.
        if normalized.contains(where: { $0.path == root.path || $0.path == meetings.path }) {
            try rebuild()
            return
        }
        let indexedFiles: Set<String> = [
            "metadata.json", "notes.md", "summary.md", TranscriptStorage.filename,
            LiveTranscriptProjection.checkpointName,
        ]
        var affectedFolders: Set<URL> = []
        for path in normalized where path.path.hasPrefix(meetings.path + "/") {
            let relative = String(path.path.dropFirst(meetings.path.count + 1)).split(separator: "/")
            guard let name = relative.first, MeetingFolderLocation.identity(String(name)) != nil else { continue }
            guard relative.count == 1 || (relative.count == 2 && indexedFiles.contains(String(relative[1]))) else {
                continue
            }
            affectedFolders.insert(meetings.appendingPathComponent(String(name)))
        }
        // Keep distinct folders for the same identity so duplicate detection still runs.
        for path in affectedFolders.sorted(by: { $0.path < $1.path }) {
            var folder = path
            while folder.path.hasPrefix(root.path + "/"), folder != root {
                if let id = MeetingFolderLocation.identity(folder.lastPathComponent),
                    folder.deletingLastPathComponent().standardized.path
                        == meetings.path
                {
                    try MeetingFolderLocation.validate(folder, directory: directory)
                    if try folderName(id: id) == "" {
                        let matches = try MeetingFolderLocation.candidates(id: id, directory: directory)
                        guard matches.count <= 1 else { throw MeetingFolderLocation.AccessError.duplicate }
                        if let remaining = matches.first {
                            let entry = try JSONDecoder().decode(
                                MeetingListEntry.self,
                                from: Data(contentsOf: remaining.appendingPathComponent("metadata.json")))
                            guard entry.id == id else {
                                throw MeetingError.message("Meeting ID differs from its folder.")
                            }
                            try upsert(entry, folder: remaining, confirmedUnique: true)
                        }
                        else {
                            try remove(id: id)
                        }
                        break
                    }
                    let metadata = folder.appendingPathComponent("metadata.json")
                    if FileManager.default.fileExists(atPath: metadata.path) {
                        let entry = try JSONDecoder().decode(MeetingListEntry.self, from: Data(contentsOf: metadata))
                        guard entry.id == id else {
                            throw MeetingError.message("Meeting ID differs from its folder.")
                        }
                        try upsert(entry, folder: folder)
                    }
                    else {
                        if let canonical = try folderName(id: id), canonical != folder.lastPathComponent,
                            FileManager.default.fileExists(
                                atPath: directory.appendingPathComponent("meetings").appendingPathComponent(canonical)
                                    .path)
                        {
                            break
                        }
                        try remove(id: id)
                    }
                    break
                }
                folder.deleteLastPathComponent()
            }
        }
    }
}
