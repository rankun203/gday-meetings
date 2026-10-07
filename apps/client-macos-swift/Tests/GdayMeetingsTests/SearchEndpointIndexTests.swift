import CSQLite
import Foundation
import Testing

@testable import GdayMeetings

struct SearchEndpointIndexTests {
    @Test func textEndpointsAreAvailableWithoutMeetingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Planning")
        meeting.duration = 60
        meeting.transcript = [.init(start: 12, end: 18, text: "Synthetic passage")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        try FileManager.default.removeItem(at: root.appendingPathComponent("meetings"))
        let result = try #require(index.searchPage(query: "passage").results.first)
        #expect(result.start == 12)
        #expect(result.end == 18)
    }

    @Test func versionThreeRebuildsLibraryAndPreservesOtherModules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connection = try IndexDatabase.open(at: root.appendingPathComponent("index.db"))
        let current = IndexDatabase.Module.library
        let tables = current.tables.map { table in
            guard table.name == "search_passages" else { return table }
            return .init(
                name: table.name,
                definition: "USING fts5(meeting UNINDEXED,kind UNINDEXED,segment UNINDEXED,start UNINDEXED,text)",
                virtual: true, copiedColumns: "rowid,meeting,kind,segment,start,text")
        }
        let old = IndexDatabase.Module(
            namespace: current.namespace, version: 3, tables: tables,
            indexes: current.indexes, initialValues: current.initialValues)
        try connection.register(old)
        let provider = IndexDatabase.Module(
            namespace: "provider_fixture", version: 1,
            tables: [.init(name: "provider_fixture_windows", definition: "(id INTEGER PRIMARY KEY)")],
            indexes: "", initialValues: "")
        try connection.register(provider)
        try connection.execute("INSERT INTO provider_fixture_windows VALUES(1); UPDATE index_state SET complete=1")
        let index = try LibraryIndex(directory: root)
        #expect(index.requiresRebuild)
        let query = try connection.prepare("SELECT count(*) FROM provider_fixture_windows")
        defer { connection.release(query) }
        #expect(sqlite3_step(query) == SQLITE_ROW)
        #expect(sqlite3_column_int(query, 0) == 1)
        var meeting = Meeting(title: "Planning")
        meeting.transcript = [.init(start: 12, end: 18, text: "Synthetic passage")]
        try MeetingFolderStorage.write(meeting, directory: root)
        try index.rebuild()
        #expect(try index.searchPage(query: "passage").results.first?.end == 18)
    }
}
