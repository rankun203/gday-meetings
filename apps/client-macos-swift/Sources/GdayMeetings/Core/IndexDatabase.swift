import CSQLite
import Foundation

/// One disposable database, with independent WAL connections for each serialized domain.
/// Only this layer opens, configures, recovers, and executes SQLite connections.
final class IndexDatabase: @unchecked Sendable {
    struct Table: Sendable {
        let name: String
        let definition: String
        var virtual = false
        var copiedColumns = "*"

        func create(temporary: Bool = false) -> String {
            "CREATE \(virtual ? "VIRTUAL " : "")TABLE IF NOT EXISTS \(temporary ? "temp." : "main.")\(name) \(definition)"
        }
    }

    /// Descriptors are compiled into trusted adapters. Provider responses never supply SQL.
    struct Module: Sendable {
        let namespace: String
        let version: Int
        let tables: [Table]
        let indexes: String
        let initialValues: String
        var legacyVersion: Int? = nil
        var retiredTables: [String] = []
    }

    private final class WeakOwner {
        weak var value: IndexDatabase?
        init(_ value: IndexDatabase) { self.value = value }
    }
    private static let registryLock = NSLock()
    private static var owners: [String: WeakOwner] = [:]
    let url: URL
    let recoveredCorruption: Bool
    private let schemaLock = NSLock()

    static func open(at url: URL) throws -> Connection {
        registryLock.lock()
        defer { registryLock.unlock() }
        let canonical = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
        let owner: IndexDatabase
        if let existing = owners[canonical.path]?.value {
            owner = existing
        }
        else {
            owner = try IndexDatabase(url: canonical)
            owners[canonical.path] = WeakOwner(owner)
        }
        return try Connection(owner: owner)
    }

    private init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var recovered = false
        do {
            if FileManager.default.fileExists(atPath: url.path + ".needs-recovery") {
                throw DatabaseError(code: SQLITE_CORRUPT, message: "A previous connection reported index corruption.")
            }
            let handle = try Self.openHandle(url)
            defer { sqlite3_close(handle) }
            try Self.execute("SELECT name FROM sqlite_schema LIMIT 1", on: handle)
        }
        catch let error as DatabaseError where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            // The registry is locked and no connection owns this file. Never replace a live database.
            let suffix = ".corrupt-" + UUID().uuidString
            for ending in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + ending)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: URL(fileURLWithPath: source.path + suffix))
                }
            }
            recovered = true
            try? FileManager.default.removeItem(atPath: url.path + ".needs-recovery")
        }
        recoveredCorruption = recovered
    }

    struct DatabaseError: LocalizedError {
        let code: Int32
        let message: String
        var errorDescription: String? { "Couldn’t access the library index. \(message)" }
    }

    private static func failure(_ handle: OpaquePointer?) -> DatabaseError {
        DatabaseError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    private static func execute(_ sql: String, on handle: OpaquePointer) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure(handle) }
    }

    private static func openHandle(_ url: URL) throws -> OpaquePointer {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isSymbolicLink == true || values.isRegularFile == false
            {
                throw DatabaseError(
                    code: SQLITE_CANTOPEN, message: "The index and its companion files must be regular files.")
            }
        }
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let error = failure(handle)
            sqlite3_close(handle)
            throw error
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            try execute(
                "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2048; PRAGMA temp_store=FILE",
                on: handle)
            configureDirectoryFunctions(handle)
            return handle
        }
        catch {
            sqlite3_close(handle)
            throw error
        }
    }

    final class Connection {
        private let owner: IndexDatabase
        let handle: OpaquePointer
        private var cached: [String: OpaquePointer] = [:]
        var isStaging: Bool { staged != nil }
        private var staged: Module?
        private var stagedRevision: Int64?
        var recoveredCorruption: Bool { owner.recoveredCorruption }
        var url: URL { owner.url }

        fileprivate init(owner: IndexDatabase) throws {
            self.owner = owner
            do { handle = try IndexDatabase.openHandle(owner.url) }
            catch let error as DatabaseError {
                if error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
                    try? Data().write(to: URL(fileURLWithPath: owner.url.path + ".needs-recovery"), options: .atomic)
                }
                throw error
            }
        }
        deinit {
            invalidateStatements()
            sqlite3_close(handle)
        }
        func failure() -> Error {
            let error = IndexDatabase.failure(handle)
            recordCorruption(error)
            return error
        }
        private func recordCorruption(_ error: DatabaseError) {
            guard error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB else { return }
            // Defer physical recovery until every live connection has closed. The marker
            // also survives an app restart without requiring a full startup integrity scan.
            try? Data().write(to: URL(fileURLWithPath: url.path + ".needs-recovery"), options: .atomic)
        }
        func execute(_ sql: String) throws {
            do { try IndexDatabase.execute(sql, on: handle) }
            catch let error as DatabaseError {
                recordCorruption(error)
                throw error
            }
        }
        func prepare(_ sql: String) throws -> OpaquePointer {
            if let statement = cached.removeValue(forKey: sql) { return statement }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw failure()
            }
            return statement
        }
        func release(_ statement: OpaquePointer) {
            let sql = String(cString: sqlite3_sql(statement))
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            if let previous = cached.updateValue(statement, forKey: sql) { sqlite3_finalize(previous) }
        }
        func invalidateStatements() {
            for statement in cached.values { sqlite3_finalize(statement) }
            cached.removeAll()
        }

        /// Provider adapters use this boundary for writes, including virtual-only modules
        /// where SQLite cannot attach ordinary row revision triggers.
        func write<T>(module: Module, _ body: () throws -> T) throws -> T {
            try execute("BEGIN IMMEDIATE")
            do {
                let value = try body()
                let update = try prepare("UPDATE main.index_modules SET revision=revision+1 WHERE namespace=?")
                sqlite3_bind_text(update, 1, module.namespace, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                let status = sqlite3_step(update)
                let changed = sqlite3_changes(handle)
                release(update)
                guard status == SQLITE_DONE else { throw failure() }
                guard changed == 1 else {
                    throw DatabaseError(
                        code: SQLITE_MISUSE, message: "Register the index module before writing its rows.")
                }
                try execute("COMMIT")
                return value
            }
            catch {
                try? execute("ROLLBACK")
                throw error
            }
        }

        @discardableResult func register(_ module: Module) throws -> Bool {
            owner.schemaLock.lock()
            defer { owner.schemaLock.unlock() }
            let identifier = "^[a-z][a-z0-9_]*$"
            guard module.namespace.range(of: identifier, options: .regularExpression) != nil,
                module.version > 0, !module.tables.isEmpty,
                Set(module.tables.map(\.name)).count == module.tables.count,
                module.tables.allSatisfy({ $0.name.range(of: identifier, options: .regularExpression) != nil }),
                module.retiredTables.allSatisfy({ $0.range(of: identifier, options: .regularExpression) != nil }),
                module.namespace.hasPrefix("core_")
                    || (module.tables.allSatisfy({ $0.name.hasPrefix(module.namespace + "_") })
                        && module.retiredTables.allSatisfy({ $0.hasPrefix(module.namespace + "_") }))
            else { throw DatabaseError(code: SQLITE_MISUSE, message: "The index module has an invalid namespace.") }
            try execute("BEGIN IMMEDIATE")
            do {
                try execute(
                    "CREATE TABLE IF NOT EXISTS index_modules(namespace TEXT PRIMARY KEY,version INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS index_module_tables(name TEXT PRIMARY KEY,namespace TEXT NOT NULL)"
                )
                let query = try prepare("SELECT version FROM index_modules WHERE namespace='\(module.namespace)'")
                let previous = sqlite3_step(query) == SQLITE_ROW ? Int(sqlite3_column_int(query, 0)) : nil
                release(query)
                var adopted = false
                if previous == nil, let legacy = module.legacyVersion {
                    let query = try prepare("PRAGMA user_version")
                    adopted = sqlite3_step(query) == SQLITE_ROW && Int(sqlite3_column_int(query, 0)) == legacy
                    release(query)
                }
                for name in module.tables.map(\.name) + module.retiredTables {
                    let query = try prepare("SELECT namespace FROM index_module_tables WHERE name='\(name)'")
                    let conflicting =
                        sqlite3_step(query) == SQLITE_ROW
                        && String(cString: sqlite3_column_text(query, 0)) != module.namespace
                    release(query)
                    guard !conflicting else {
                        throw DatabaseError(code: SQLITE_MISUSE, message: "Two index modules own the same table.")
                    }
                }
                let reset = previous != module.version && !adopted
                if reset {
                    for table in module.tables { try execute("DROP TABLE IF EXISTS main.\(table.name)") }
                    for name in module.retiredTables {
                        try execute(
                            "DROP TABLE IF EXISTS main.\(name); DELETE FROM index_module_tables WHERE name='\(name)'")
                    }
                }
                for table in module.tables {
                    try execute(table.create())
                    try execute(
                        "INSERT OR REPLACE INTO index_module_tables VALUES('\(table.name)','\(module.namespace)')")
                }
                try execute(module.indexes)
                try execute(module.initialValues)
                try execute(
                    "INSERT INTO index_modules(namespace,version) VALUES('\(module.namespace)',\(module.version)) ON CONFLICT(namespace) DO UPDATE SET version=excluded.version,revision=index_modules.revision+CASE WHEN index_modules.version<>excluded.version THEN 1 ELSE 0 END"
                )
                for table in module.tables where !table.virtual {
                    for operation in ["INSERT", "UPDATE", "DELETE"] {
                        try execute(
                            "CREATE TRIGGER IF NOT EXISTS \(table.name)_revision_\(operation.lowercased()) AFTER \(operation) ON \(table.name) BEGIN UPDATE index_modules SET revision=revision+1 WHERE namespace='\(module.namespace)'; END"
                        )
                    }
                }
                try execute("COMMIT")
                try updateGuide()
                return reset
            }
            catch {
                try? execute("ROLLBACK")
                throw error
            }
        }

        /// TEMP staging keeps file I/O and decoding outside the shared WAL writer transaction.
        /// The caller serializes this connection; other connections retain the committed generation.
        func beginStaging(_ module: Module, preservingRows: Bool) throws {
            guard staged == nil else {
                throw DatabaseError(code: SQLITE_MISUSE, message: "An index rebuild is already running.")
            }
            invalidateStatements()
            staged = module
            do {
                try execute("BEGIN")
                stagedRevision = try revision(module)
                for table in module.tables {
                    try execute(table.create(temporary: true))
                    if preservingRows { try copy(table, from: "main", to: "temp") }
                }
                try execute(module.initialValues)
                try execute("COMMIT")
            }
            catch {
                try? execute("ROLLBACK")
                discardStaging()
                throw error
            }
        }
        func publishStaging() throws {
            guard let module = staged else { return }
            invalidateStatements()
            try execute("BEGIN IMMEDIATE")
            do {
                guard try revision(module) == stagedRevision else {
                    throw DatabaseError(
                        code: SQLITE_BUSY,
                        message:
                            "The index changed during its rebuild. Rebuild the index again to include the updated files."
                    )
                }
                for table in module.tables {
                    try execute("DELETE FROM main.\(table.name)")
                    try copy(table, from: "temp", to: "main")
                }
                try execute("COMMIT")
                discardStaging()
            }
            catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
        func discardStaging() {
            invalidateStatements()
            if let module = staged {
                for table in module.tables { try? execute("DROP TABLE IF EXISTS temp.\(table.name)") }
            }
            staged = nil
            stagedRevision = nil
        }
        private func revision(_ module: Module) throws -> Int64 {
            let query = try prepare("SELECT revision FROM main.index_modules WHERE namespace='\(module.namespace)'")
            defer { release(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(query, 0)
        }
        private func copy(_ table: Table, from source: String, to target: String) throws {
            let columns = table.copiedColumns == "*" ? "" : "(\(table.copiedColumns))"
            try execute(
                "INSERT INTO \(target).\(table.name)\(columns) SELECT \(table.copiedColumns) FROM \(source).\(table.name)"
            )
        }
    }
}

extension IndexDatabase {
    private static func configureDirectoryFunctions(_ handle: OpaquePointer) {
        sqlite3_create_collation(handle, "GDAY_NAME", SQLITE_UTF8, nil) { _, leftCount, left, rightCount, right in
            let lhs = String(
                decoding: UnsafeBufferPointer(start: left?.assumingMemoryBound(to: UInt8.self), count: Int(leftCount)),
                as: UTF8.self)
            let rhs = String(
                decoding: UnsafeBufferPointer(
                    start: right?.assumingMemoryBound(to: UInt8.self), count: Int(rightCount)), as: UTF8.self)
            return Int32(lhs.localizedStandardCompare(rhs).rawValue)
        }
        sqlite3_create_function_v2(
            handle, "GDAY_CONTAINS", 2, SQLITE_UTF8, nil,
            { context, _, arguments in
                guard let arguments, let left = sqlite3_value_text(arguments[0]),
                    let right = sqlite3_value_text(arguments[1])
                else {
                    sqlite3_result_int(context, 0)
                    return
                }
                let source = String(cString: left)
                let query = String(cString: right)
                sqlite3_result_int(context, query.isEmpty || source.localizedStandardContains(query) ? 1 : 0)
            }, nil, nil, nil)
        sqlite3_create_function_v2(
            handle, "GDAY_EQUAL", 2, SQLITE_UTF8, nil,
            { context, _, arguments in
                guard let arguments, let left = sqlite3_value_text(arguments[0]),
                    let right = sqlite3_value_text(arguments[1])
                else {
                    sqlite3_result_int(context, 0)
                    return
                }
                let source = String(cString: left)
                let query = String(cString: right)
                sqlite3_result_int(
                    context,
                    source.compare(query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        == .orderedSame ? 1 : 0)
            }, nil, nil, nil)
    }
}
