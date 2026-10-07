import CSQLite
import Foundation
import Testing

@testable import GdayMeetings

struct RetiredVoiceSearchMigrationTests {
    @Test func emptyLibraryNeedsNoMeetingDirectoryOrDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try RetiredVoiceSearchMigration.removeIndexNamespace(indexDirectory: root)
        try RetiredVoiceSearchMigration.removeArtifacts(directory: root, indexDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("index.db").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("retired-voice-search-v1").path))
    }

    @Test func obsoleteRegistrationIsRemovedWithoutRetiredTables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.db")
        var original: IndexDatabase.Connection? = try IndexDatabase.open(at: url)
        try original!.execute(
            "CREATE TABLE index_modules(namespace TEXT); INSERT INTO index_modules VALUES('provider_clsp'); INSERT INTO index_modules VALUES('preserved')"
        )
        original = nil
        try RetiredVoiceSearchMigration.removeIndexNamespace(indexDirectory: root)
        let reopened = try IndexDatabase.open(at: url)
        let query = try reopened.prepare("SELECT namespace FROM index_modules")
        defer { reopened.release(query) }
        #expect(sqlite3_step(query) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(query, 0)) == "preserved")
        #expect(sqlite3_step(query) == SQLITE_DONE)
    }

    @Test func retiredWeightsRemoveOnlyTheirUnreferencedObjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let retired = root.appendingPathComponent("clsp/v1")
        let community = root.appendingPathComponent("community1/v1")
        let objects = root.appendingPathComponent("objects")
        for folder in [retired, community, objects] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let disposable = objects.appendingPathComponent("retired-object")
        let shared = objects.appendingPathComponent("shared-object")
        for object in [disposable, shared] {
            try Data("synthetic weights".utf8).write(to: object)
            try FileManager.default.linkItem(at: object, to: retired.appendingPathComponent(object.lastPathComponent))
        }
        try FileManager.default.linkItem(at: shared, to: community.appendingPathComponent("shared"))
        try RetiredVoiceSearchMigration.removeModels(root: root)
        try RetiredVoiceSearchMigration.removeModels(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("clsp").path))
        #expect(!FileManager.default.fileExists(atPath: disposable.path))
        #expect(FileManager.default.fileExists(atPath: shared.path))
        #expect(try Data(contentsOf: community.appendingPathComponent("shared")) == Data("synthetic weights".utf8))
    }

    @Test func removesOnlyDerivedRetiredArtifactsAndTables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = root.appendingPathComponent("meetings/synthetic")
        let retired = meeting.appendingPathComponent("providers/\(RetiredVoiceSearchMigration.providerID)/embeddings")
        let community = meeting.appendingPathComponent("providers/synthetic-community/embeddings")
        for folder in [retired, community] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("synthetic derived data".utf8).write(to: folder.appendingPathComponent("data"))
        }
        for file in ["transcript.json", "audio.wav", "metadata.json"] {
            try Data("synthetic source".utf8).write(to: meeting.appendingPathComponent(file))
        }
        let databaseURL = root.appendingPathComponent("index.db")
        var connection: IndexDatabase.Connection? = try IndexDatabase.open(at: databaseURL)
        try connection?.execute(
            "CREATE TABLE provider_clsp_sources(id TEXT); CREATE TABLE provider_clsp_clips(id TEXT); CREATE TABLE provider_clsp_state(id TEXT); CREATE TABLE preserved(id TEXT)"
        )
        connection = nil
        try RetiredVoiceSearchMigration.removeIndexNamespace(indexDirectory: root)
        let reopened = try IndexDatabase.open(at: databaseURL)
        let query = try reopened.prepare("SELECT name FROM sqlite_schema WHERE name='preserved'")
        reopened.release(query)
        #expect(throws: (any Error).self) { _ = try reopened.prepare("SELECT * FROM provider_clsp_sources") }
        try RetiredVoiceSearchMigration.removeArtifacts(directory: root, indexDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(FileManager.default.fileExists(atPath: community.appendingPathComponent("data").path))
        for file in ["transcript.json", "audio.wav", "metadata.json"] {
            #expect(try Data(contentsOf: meeting.appendingPathComponent(file)) == Data("synthetic source".utf8))
        }
        try RetiredVoiceSearchMigration.removeArtifacts(directory: root, indexDirectory: root)
    }
}
