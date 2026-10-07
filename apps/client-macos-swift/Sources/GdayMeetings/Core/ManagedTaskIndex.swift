import CSQLite
import CryptoKit
import Foundation

/// Disposable locations into the authoritative journal. No task payload is duplicated here.
final class ManagedTaskIndex {
    struct Location {
        let offset: UInt64
        let length: Int
        let id: String
        let digest: String
    }
    private let connection: IndexDatabase.Connection
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        connection = try IndexDatabase.open(at: url)
        try connection.register(.tasks)
    }
    private func failure() -> Error { connection.failure() }
    func execute(_ sql: String) throws { try connection.execute(sql) }
    private func statement(_ sql: String) throws -> OpaquePointer { try connection.prepare(sql) }
    func publishRebuild() throws { try connection.publishStaging() }
    func discardRebuild() { connection.discardStaging() }
    static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    func revision() throws -> (String, UInt64)? {
        let query = try statement("SELECT revision,committed FROM journal_revision WHERE id=1")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, let text = sqlite3_column_text(query, 0) else { return nil }
        return (String(cString: text), UInt64(sqlite3_column_int64(query, 1)))
    }
    func setRevision(_ revision: String, committed: UInt64) throws {
        try execute("INSERT OR REPLACE INTO journal_revision VALUES(1,\(Self.literal(revision)),\(committed))")
    }
    func clear() throws {
        try execute(
            "DROP TABLE IF EXISTS temp.previous_offsets; CREATE TEMP TABLE previous_offsets AS SELECT id,intent_digest FROM task_offsets; CREATE INDEX previous_task_id ON previous_offsets(id)"
        )
        try connection.beginStaging(.tasks, preservingRows: false)
    }
    func changedSinceRebuild(_ id: UUID) throws -> Bool {
        let query = try statement(
            "SELECT count(*) FROM task_offsets current LEFT JOIN previous_offsets previous ON current.id=previous.id WHERE current.id=\(Self.literal(id.uuidString)) AND (previous.id IS NULL OR current.intent_digest!=previous.intent_digest)"
        )
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int(query, 0) > 0
    }
    func remove(_ id: UUID) throws { try execute("DELETE FROM task_offsets WHERE id=\(Self.literal(id.uuidString))") }
    func upsert(_ record: ManagedTaskRecord, offset: UInt64, length: Int, digest: String) throws {
        let query = try statement("INSERT OR REPLACE INTO task_offsets VALUES(?,?,?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(query) }
        for (position, value) in [
            (1, record.id.uuidString), (3, record.state.rawValue), (4, record.kind.rawValue),
            (5, record.meetingID.uuidString),
        ] {
            sqlite3_bind_text(query, Int32(position), value, -1, transient)
        }
        sqlite3_bind_double(query, 2, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_int64(query, 6, record.queuePriority)
        sqlite3_bind_int64(query, 7, Int64(offset))
        sqlite3_bind_int64(query, 8, Int64(length))
        sqlite3_bind_text(query, 9, digest, -1, transient)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let contentDigest = SHA256.hash(data: try encoder.encode(ManagedTaskExecutionIntent(record))).description
        sqlite3_bind_text(query, 10, contentDigest, -1, transient)
        sqlite3_bind_int(query, 11, record.needsAttention ? 1 : 0)
        sqlite3_bind_int(query, 12, record.isAutomatic ? 1 : 0)
        guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
    }
    func locations(where predicate: String = "1", order: String = "created DESC,id DESC", limit: Int) throws
        -> [Location]
    {
        let query = try statement(
            "SELECT offset,length,id,digest FROM task_offsets WHERE \(predicate) ORDER BY \(order) LIMIT \(max(0,limit))"
        )
        defer { sqlite3_finalize(query) }
        var result: [Location] = []
        while true {
            switch sqlite3_step(query) {
            case SQLITE_ROW:
                let offset = sqlite3_column_int64(query, 0)
                let length = sqlite3_column_int64(query, 1)
                guard offset >= 0, length > 0, length <= 8 * 1_024 * 1_024,
                    let id = sqlite3_column_text(query, 2), let digest = sqlite3_column_text(query, 3)
                else { throw failure() }
                result.append(
                    Location(
                        offset: UInt64(offset), length: Int(length), id: String(cString: id),
                        digest: String(cString: digest)))
            case SQLITE_DONE: return result
            default: throw failure()
            }
        }
    }
    func count(where predicate: String = "1") throws -> Int {
        let query = try statement("SELECT count(*) FROM task_offsets WHERE \(predicate)")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(query, 0))
    }
}
