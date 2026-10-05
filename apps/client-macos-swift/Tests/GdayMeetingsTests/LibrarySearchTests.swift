import CSQLite
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LibrarySearchTests {
    @Test func indexedPassagesPageWithoutReadingMeetingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Planning fixture")
        meeting.summary = "Planning summary"
        meeting.transcript = (0..<105).map { number in
            TranscriptSegment(start: Double(number), end: Double(number + 1), text: "Planning passage \(number)")
        }
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        // Once indexed, search must not open meeting folders or decode transcripts.
        try FileManager.default.removeItem(at: root.appendingPathComponent("meetings"))
        let first = try index.searchPage(query: "Planning", limit: 50)
        let second = try index.searchPage(query: "Planning", after: #require(first.results.last?.id), limit: 50)
        let third = try index.searchPage(query: "Planning", after: #require(second.results.last?.id), limit: 50)
        let all = first.results + second.results + third.results
        #expect(first.total == 107)
        #expect(first.results.count == 50)
        #expect(second.results.count == 50)
        #expect(third.results.count == 7)
        #expect(Set(all.map(\.id)).count == 107)
        let transcript = try #require(all.first { $0.segmentID == meeting.transcript[73].id })
        #expect(transcript.kind == .transcript)
        #expect(transcript.start == 73)
        #expect(transcript.excerpt.contains("73"))
        #expect(try index.searchPage(query: "unmatched").total == 0)
        #expect(try index.searchPage(query: "  ").results.isEmpty)
        #expect(try index.searchPage(query: "\" OR planning").results.isEmpty)
    }

    @Test func updatesAndRemovalReplacePassageLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Search fixture")
        meeting.transcript = [TranscriptSegment(start: 5, end: 8, text: "originalpassage")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        meeting.transcript = [TranscriptSegment(start: 15, end: 18, text: "replacementpassage")]
        try MeetingFolderStorage.write(meeting, directory: root)
        try index.upsert(MeetingListEntry(meeting))
        #expect(try index.searchPage(query: "originalpassage").total == 0)
        #expect(try index.searchPage(query: "replacementpassage").results.first?.start == 15)
        try index.remove(id: meeting.id)
        #expect(try index.searchPage(query: "replacementpassage").total == 0)
    }

    @Test func submissionSeparatesDraftAndSupersedesDelayedCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try LibraryIndex(directory: root)
        let gate = SearchCompletionGate()
        let session = LibrarySearchSession(loadPage: { _, query, _, _ in
            await gate.wait(query)
            return LibrarySearchPage(results: [], total: query == "first" ? 1 : 2)
        })
        #expect(session.submit(" first ", index: index))
        await gate.waitUntilStarted("first")
        #expect(session.query == "first")
        #expect(!session.submit(" \n ", index: index))
        #expect(session.query == "first")
        #expect(session.submit("second", index: index))
        await gate.waitUntilStarted("second")
        await gate.finish("second")
        let secondCompleted = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            !session.isLoading
        }
        #expect(secondCompleted)
        #expect(session.query == "second")
        #expect(session.total == 2)
        await gate.finish("first")
        for _ in 0..<100 { await Task.yield() }
        #expect(session.total == 2)
        #expect(!session.isLoading)
    }

    @Test func metadataSaveDefersPassagesToBackgroundReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Search save fixture")
        meeting.transcript = [TranscriptSegment(start: 5, end: 8, text: "originalneedle")]
        try MeetingFolderStorage.write(meeting, directory: root)
        try LibraryIndex(directory: root).rebuild()
        let store = MeetingStore(dataDirectory: root)
        let index = try #require(store.libraryIndex)
        let settled = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            !store.libraryDataStatus.isBuilding
        }
        #expect(settled)
        let originalID = try #require(try index.searchPage(query: "originalneedle").results.first?.id)
        meeting.title = "Updated search fixture"
        #expect(await store.updateMeeting(meeting))
        let updated = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            (try? index.searchPage(query: "Updated").total) == 1
        }
        #expect(updated)
        #expect(try index.searchPage(query: "originalneedle").results.first?.id == originalID)
        meeting.transcript[0].text = "replacementneedle"
        #expect(await store.updateMeeting(meeting))
        let replaced = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            (try? index.searchPage(query: "replacementneedle").total) == 1
        }
        #expect(replaced)
        #expect(try index.searchPage(query: "originalneedle").total == 0)
        let folder = store.directory(for: meeting.id)
        try FileManager.default.removeItem(at: folder)
        store.libraryMonitor?.process(.init(paths: [folder], requiresScan: false, eventID: 0))
        let removed = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            (try? index.searchPage(query: "replacementneedle").total) == 0
        }
        #expect(removed)
        await store.libraryMonitor?.stop()
        #expect(try index.entry(id: meeting.id) == nil)
    }

    @Test func metadataOnlyUpdateDoesNotReadTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Original fixture")
        meeting.transcript = [TranscriptSegment(text: "retainedneedle")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        try Data("invalid".utf8).write(to: folder.appendingPathComponent(TranscriptStorage.filename))
        meeting.title = "Updated fixture"
        try index.upsert(MeetingListEntry(meeting), refreshSearch: false)
        #expect(try index.entry(id: meeting.id)?.title == "Updated fixture")
        #expect(try index.searchPage(query: "retainedneedle").total == 1)
        #expect(throws: (any Error).self) { try index.upsert(MeetingListEntry(meeting)) }
        #expect(try index.searchPage(query: "retainedneedle").total == 1)
    }

    @Test func excerptsUseVisibleMarkdownText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Markdown fixture")
        meeting.summary = "# Summary\n\nReview [planning notes](https://example.invalid/hiddenpath) and **next steps**."
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let notes = """
            # Planning <!-- gday:t=0:05 -->
            - Review **meeting notes** <!-- gday:t=0:12 -->
            - [ ] Read [planning guide](https://example.invalid/hiddentarget)
            ![Planning diagram](assets/hiddenimage.png)
            """
        try Data(notes.utf8).write(to: folder.appendingPathComponent("notes.md"))
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let results = try index.searchPage(query: "planning").results
        #expect(results.count == 2)
        let excerpt = try #require(results.first { $0.kind == .notes }?.excerpt)
        #expect(excerpt.contains("meeting notes"))
        #expect(excerpt.contains("planning guide"))
        #expect(excerpt.contains("Planning diagram"))
        for hidden in ["gday:t", "<!--", "**", "[ ]", "hiddentarget", "hiddenimage"] {
            #expect(!excerpt.contains(hidden))
        }
        #expect(try index.searchPage(query: "hiddenpath").total == 0)
        #expect(try index.searchPage(query: "hiddentarget").total == 0)
        #expect(try index.searchPage(query: "hiddenimage").total == 0)
    }

    @Test func excludedTagsFilterCountsAndPagesBeforeLimiting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let excluded = UUID()
        var hidden = Meeting(title: "Planning hidden fixture")
        hidden.tagIDs = [excluded]
        hidden.transcript = [TranscriptSegment(text: "Planning hidden passage")]
        let visible = Meeting(title: "Planning visible fixture")
        try MeetingFolderStorage.write(hidden, directory: root)
        try MeetingFolderStorage.write(visible, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        #expect(try index.searchPage(query: "Planning").total == 3)
        let filtered = try index.searchPage(query: "Planning", limit: 1, excludingTagIDs: [excluded])
        #expect(filtered.total == 1)
        #expect(filtered.results.map(\.meetingID) == [visible.id])
        let next = try index.searchPage(
            query: "Planning", after: #require(filtered.results.last?.id), limit: 1, excludingTagIDs: [excluded])
        #expect(next.results.isEmpty)
    }

    @Test func versionTwoIndexRebuildsWithoutChangingAuthoritativeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Migration fixture")
        meeting.transcript = [TranscriptSegment(start: 4, end: 6, text: "migrationneedle")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let transcript = MeetingFolderStorage.folder(id: meeting.id, directory: root)
            .appendingPathComponent(TranscriptStorage.filename)
        let original = try Data(contentsOf: transcript)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("index.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let schema = """
            CREATE TABLE meetings(id TEXT PRIMARY KEY);
            CREATE VIRTUAL TABLE search USING fts5(id UNINDEXED,text);
            CREATE TABLE index_state(id INTEGER PRIMARY KEY,complete INTEGER NOT NULL);
            INSERT INTO index_state VALUES(1,1);
            PRAGMA user_version=2;
            """
        #expect(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
        let index = try LibraryIndex(directory: root)
        #expect(index.requiresRebuild)
        #expect(try index.searchPage(query: "migrationneedle").total == 0)
        try index.rebuild()
        #expect(!index.requiresRebuild)
        let result = try #require(try index.searchPage(query: "migrationneedle").results.first)
        #expect(result.segmentID == meeting.transcript.first?.id)
        #expect(result.start == 4)
        #expect(try Data(contentsOf: transcript) == original)
    }

    @Test func missingIndexHasRecoverableError() {
        let session = LibrarySearchSession()
        #expect(session.submit("Planning", index: nil))
        #expect(session.error != nil)
        #expect(!session.isLoading)
        #expect(session.query == "Planning")
    }
}

private actor SearchCompletionGate {
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    func wait(_ query: String) async {
        await withCheckedContinuation { continuations[query] = $0 }
    }
    func waitUntilStarted(_ query: String) async {
        while continuations[query] == nil { await Task.yield() }
    }
    func finish(_ query: String) { continuations.removeValue(forKey: query)?.resume() }
}
