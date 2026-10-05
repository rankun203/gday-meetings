import CSQLite
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct DirectoryPagingTests {
    private func fixture(count: Int) throws -> (URL, DirectoryIndex, [Person]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-tests-\(UUID())")
        let people = (0..<count).map { Person(name: "Person \($0)") }
        try FileEntityStorage.save(people, previous: [], kind: "people", directory: root)
        let index = try DirectoryIndex(root: root, indexDirectory: root)
        try index.reconcile(paths: [], rebuild: true)
        return (root, index, people)
    }
    @Test func cursorPagesAreNaturalOrderedAndDoNotReadFiles() throws {
        let (root, index, people) = try fixture(count: 125)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("people"))
        let first = try index.page(kind: .people)
        #expect(first.total == 125)
        #expect(first.entries.map(\.name) == (0..<50).map { "Person \($0)" })
        let second = try index.page(kind: .people, after: first.entries.last)
        let third = try index.page(kind: .people, after: second.entries.last)
        #expect(third.entries.count == 25)
        #expect(Set((first.entries + second.entries + third.entries).map(\.id)).count == 125)
        let previous = try index.page(kind: .people, before: second.entries.first)
        #expect(previous.entries == first.entries)
        #expect(try index.exactPerson(name: "person 124") == people[124].id)
    }
    @Test func targetedReconciliationExcludesBeforePagingAndPreservesUnrelatedRows() throws {
        let (root, index, people) = try fixture(count: 80)
        defer { try? FileManager.default.removeItem(at: root) }
        let excluded = MeetingTag(name: "Hidden", isExcluded: true)
        try FileEntityStorage.save([excluded], previous: [], kind: "tags", directory: root)
        var changed = people[0]
        changed.tagIDs = [excluded.id]
        let changedPath = root.appendingPathComponent("people/\(changed.id.uuidString).json")
        try JSONEncoder().encode(changed).write(to: changedPath)
        let unrelatedPath = root.appendingPathComponent("people/\(people[79].id.uuidString).json")
        try Data("invalid".utf8).write(to: unrelatedPath)
        try index.reconcile(paths: [changedPath, root.appendingPathComponent("tags/\(excluded.id.uuidString).json")])
        #expect(try index.exactTag(name: "HIDDEN") == excluded.id)
        let page = try index.page(kind: .people)
        #expect(page.total == 79)
        #expect(page.entries.first?.name == "Person 1")
        #expect(page.entries.count == 50)
        #expect(try index.page(kind: .people, showExcluded: true).entries.first?.isExcluded == true)
        #expect(try index.exactPerson(name: "Person 79") == people[79].id)
        #expect(throws: (any Error).self) { try index.reconcile(paths: [unrelatedPath]) }
        #expect(try index.exactPerson(name: "Person 79") == people[79].id)
        try FileManager.default.removeItem(at: changedPath)
        try index.reconcile(paths: [changedPath])
        #expect(try index.page(kind: .people, showExcluded: true).total == 79)
    }
    @Test func filteringMatchesAccentsAndCountsComeFromRelationshipIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let person = Person(name: "Renée")
        try FileEntityStorage.save([person], previous: [], kind: "people", directory: root)
        var meeting = Meeting(title: "Association fixture")
        meeting.personIDs = [person.id]
        try MeetingFolderStorage.write(meeting, directory: root)
        try LibraryIndex(directory: root).rebuild()
        let index = try DirectoryIndex(root: root, indexDirectory: root)
        try index.reconcile(paths: [], rebuild: true)
        let page = try index.page(kind: .people, query: "renee")
        #expect(page.total == 1)
        #expect(page.entries.first?.meetingCount == 1)
        #expect(try index.exactPerson(name: "RENEE") == person.id)
    }
    @Test func disposableCorruptionAndSchemaResetPreserveDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let person = Person(name: "Recovery fixture")
        try FileEntityStorage.save([person], previous: [], kind: "people", directory: root)
        let file = root.appendingPathComponent("people/\(person.id.uuidString).json")
        let original = try Data(contentsOf: file)
        let databaseURL = root.appendingPathComponent("index.db")
        try Data("not a database".utf8).write(to: databaseURL)
        do {
            let index = try DirectoryIndex(root: root, indexDirectory: root)
            try index.reconcile(paths: [])
            #expect(try index.exactPerson(name: "Recovery fixture") == person.id)
        }
        let preserved = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(preserved.contains { $0.hasPrefix("index.db.corrupt-") })
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        #expect(
            sqlite3_exec(database, "UPDATE index_modules SET version=0 WHERE namespace='core_directory'", nil, nil, nil)
                == SQLITE_OK)
        sqlite3_close(database)
        let rebuilt = try DirectoryIndex(root: root, indexDirectory: root)
        try rebuilt.reconcile(paths: [])
        #expect(try rebuilt.exactPerson(name: "Recovery fixture") == person.id)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func revealsRenamedKeptPersonAfterIndexCommitWithoutFollowingScrollSelection() async throws {
        let (root, index, people) = try fixture(count: 125)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = DirectoryPaging()
        page.configure(index: index, kind: .people, query: "", showExcluded: true)
        let loaded = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !page.loading }
        #expect(loaded)
        var kept = people[0]
        kept.name = "Zulu kept person"
        let file = root.appendingPathComponent("people/\(kept.id.uuidString).json")
        try JSONEncoder().encode(kept).write(to: file)
        // Merge/add UI requests a reveal before its background index commit.
        page.reveal(kept.id, query: "", expectedName: kept.name)
        let oldIndexRead = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !page.loading }
        #expect(oldIndexRead)
        #expect(page.revealRequest == nil)
        try index.reconcile(paths: [file])
        page.configure(index: index, kind: .people, query: "", showExcluded: true)
        let revealed = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !page.loading }
        #expect(revealed)
        #expect(page.entries.last?.id == kept.id)
        #expect(page.entries.last?.name == kept.name)
        #expect(page.revealRequest?.targetID == kept.id)
        let token = page.revealRequest?.id
        page.viewport(first: try #require(page.entries.first?.id), last: try #require(page.entries.prefix(10).last?.id))
        let scrolled = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !page.loading }
        #expect(scrolled)
        #expect(page.revealRequest?.id == token)
        #expect(page.entries.count <= DirectoryPaging.windowLimit)
    }

    @Test func refreshRecoversWhenEveryRowMovesBeforeItsAnchor() async throws {
        let (root, index, people) = try fixture(count: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = DirectoryPaging()
        page.configure(index: index, kind: .people, query: "", showExcluded: true)
        let loaded = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !page.loading }
        #expect(loaded)
        var changed = people[0]
        changed.name = "Alpha"
        let file = root.appendingPathComponent("people/\(changed.id.uuidString).json")
        try JSONEncoder().encode(changed).write(to: file)
        try index.reconcile(paths: [file])
        page.configure(index: index, kind: .people, query: "", showExcluded: true)
        let refreshed = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !page.loading }
        #expect(refreshed)
        #expect(page.total == 1)
        #expect(page.entries.first?.name == "Alpha")
    }

    @Test func modelRotatesBoundedWindowForwardAndBackward() async throws {
        let (root, index, _) = try fixture(count: 1200)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = DirectoryPaging()
        page.configure(index: index, kind: .people, query: "", showExcluded: false)
        func settled() async throws {
            let finished = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !page.loading }
            #expect(finished)
            #expect(page.error == nil)
            #expect(page.entries.count <= DirectoryPaging.windowLimit)
        }
        try await settled()
        for _ in 0..<13 {
            page.viewport(
                first: try #require(page.entries.suffix(10).first?.id), last: try #require(page.entries.last?.id))
            try await settled()
        }
        #expect(page.entries.first?.name != "Person 0")
        #expect(page.entries.count == DirectoryPaging.windowLimit)
        for _ in 0..<13 {
            page.viewport(
                first: try #require(page.entries.first?.id), last: try #require(page.entries.prefix(10).last?.id))
            try await settled()
        }
        #expect(page.entries.first?.name == "Person 0")
        #expect(page.total == 1200)
    }
}
