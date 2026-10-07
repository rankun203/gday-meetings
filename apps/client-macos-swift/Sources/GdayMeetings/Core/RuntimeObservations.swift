import CSQLite
import Foundation

/// Optional, disposable runtime measurements. Missing or invalid values use the caller's fallback.
actor RuntimeObservations {
    private let connection: IndexDatabase.Connection
    private static let module = IndexDatabase.Module(
        namespace: "core_runtime", version: 1,
        tables: [.init(name: "runtime_observations", definition: "(key TEXT PRIMARY KEY,value REAL NOT NULL)")],
        indexes: "", initialValues: "")

    init(indexDirectory: URL) throws {
        connection = try IndexDatabase.open(at: indexDirectory.appendingPathComponent("index.db"))
        try connection.register(Self.module)
    }

    func value(for key: String) throws -> Double? {
        let statement = try connection.prepare("SELECT value FROM runtime_observations WHERE key=?")
        defer { connection.release(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw connection.failure() }
        let value = sqlite3_column_double(statement, 0)
        return value.isFinite && value > 0 ? value : nil
    }

    func record(_ value: Double, for key: String) throws {
        guard value.isFinite, value > 0 else { return }
        try connection.write(module: Self.module) {
            let statement = try connection.prepare(
                "INSERT INTO runtime_observations(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
            )
            defer { connection.release(statement) }
            sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(statement, 2, value)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw connection.failure() }
        }
    }
}
