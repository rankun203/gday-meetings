import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct MeetingPagingTests {
    @Test func incrementalIndexRejectsChangedMetadataIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Meeting(title: "Original")
        try MeetingFolderStorage.write(original, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let metadata = MeetingFolderStorage.folder(id: original.id, directory: root)
            .appendingPathComponent("metadata.json")
        let changed = MeetingListEntry(Meeting(title: "Wrong identity"))
        let bytes = try JSONEncoder().encode(changed)
        try bytes.write(to: metadata)
        #expect(throws: (any Error).self) { try index.reconcile(paths: [metadata]) }
        #expect(try index.count() == 1)
        #expect(try index.entry(id: original.id)?.title == "Original")
        #expect(try index.entry(id: changed.id) == nil)
        #expect(try Data(contentsOf: metadata) == bytes)
    }

    private func fixture() throws -> (URL, [Meeting]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var meetings: [Meeting] = []
        for number in 0..<45 {
            var meeting = Meeting(
                title: "Meeting \(number)", createdAt: Date(timeIntervalSince1970: Double(1000 - number)))
            meeting.transcript = [TranscriptSegment(text: number == 44 ? "uniquepastpage" : "Transcript")]
            try MeetingFolderStorage.write(meeting, directory: directory)
            meetings.append(meeting)
        }
        try LibraryIndex(directory: directory).rebuild()
        return (directory, meetings)
    }
    @Test func pagesMetadataWithoutHydratingPayloads() async throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        #expect(store.meetingCatalog.count == 20)
        #expect(store.meetings.isEmpty)
        #expect(store.visibleMeetingIDs == Array(original.prefix(20).map(\.id)))
        store.loadNextMeetingPage()
        #expect(store.meetings.isEmpty)
        #expect(store.visibleMeetingIDs.count == 40)
        await store.searchMeetingPages("uniquepastpage")
        #expect(store.visibleMeetingIDs == [original[44].id])
        #expect(store.meetings.isEmpty)
        #expect(store.meeting(id: original[44].id)?.transcript == original[44].transcript)
    }
    @Test func rebuildRecoversFilesAndRelationships() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        let tag = UUID()
        var changed = original[25]
        changed.personIDs = [person]
        changed.tagIDs = [tag]
        try MeetingFolderStorage.write(changed, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        #expect(try index.count() == 45)
        #expect(try index.count(personID: person) == 1)
        #expect(try index.page(tagID: tag).map(\.id) == [changed.id])
        var all: [MeetingListEntry] = []
        while true {
            let page = try index.page(after: all.last, limit: 7)
            all.append(contentsOf: page)
            if page.isEmpty { break }
        }
        #expect(all.map(\.id) == original.map(\.id))
    }
    @Test func compactIdentityRoundTripAndMinimalFolder() throws {
        for _ in 0..<100 {
            let id = MeetingIdentity.newID()
            #expect(MeetingIdentity.string(id).count <= 13)
            #expect(MeetingIdentity.parse(MeetingIdentity.string(id)) == id)
            let random = UUID()
            #expect(MeetingIdentity.parse(MeetingIdentity.string(random)) == random)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Dropped recording", audioFiles: ["audio.wav"])
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(MeetingListEntry(meeting)).write(to: folder.appendingPathComponent("metadata.json"))
        let read = try MeetingFolderStorage.read(id: meeting.id, directory: root)
        #expect(read.id == meeting.id)
        #expect(read.title == meeting.title)
        #expect(read.transcript.isEmpty)
        #expect(read.audioFiles == ["audio.wav"])
    }
    @Test func corruptDisposableIndexDoesNotDamageDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Keep this meeting")
        try MeetingFolderStorage.write(meeting, directory: root)
        try Data("not a database".utf8).write(to: root.appendingPathComponent("index.db"))
        let index = try LibraryIndex(directory: root)
        #expect(index.recoveredCorruptIndex)
        try index.rebuild()
        #expect(try index.count() == 1)
        #expect(try MeetingFolderStorage.read(id: meeting.id, directory: root).title == meeting.title)
    }
    @Test func malformedDocumentDoesNotDiscardOtherIndexedMeetings() throws {
        let (root, meetings) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try LibraryIndex(directory: root)
        let file = MeetingFolderStorage.folder(id: meetings[0].id, directory: root).appendingPathComponent(
            "metadata.json")
        try Data("{".utf8).write(to: file)
        try index.rebuild()
        #expect(index.lastRebuildErrorCount == 1)
        #expect(try index.count() == 45)
        #expect(try index.entry(id: meetings[0].id)?.title == meetings[0].title)
    }

    @Test func speakerRelationshipsDoNotCauseFalseExternalConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        var meeting = Meeting(title: "Conversation")
        var speaker = MeetingSpeaker(label: "Speaker", track: "microphone", providerName: "Fixture")
        speaker.personID = UUID()
        meeting.speakers = [speaker]
        try store.insertImportedMeeting(meeting)
        meeting.summary = "Updated summary"
        #expect(store.updateMeeting(meeting))
        #expect(store.errorMessage == nil)
        #expect(store.directory(for: meeting.id).deletingLastPathComponent().lastPathComponent == "meetings")
    }

    @Test func cursorPagesUseOrderedRangeIndexesWithoutSorting() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tag = UUID()
        var records = original
        for position in records.indices {
            records[position].tagIDs = [tag]
            records[position].createdAt = Date(timeIntervalSince1970: Double(position / 3))
            try MeetingFolderStorage.write(records[position], directory: root)
        }
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let expected = records.map(MeetingListEntry.init).sorted(by: MeetingListEntry.newestFirst)
        for filtered in [false, true] {
            let first = try index.page(limit: 20, tagID: filtered ? tag : nil)
            let second = try index.page(after: first.last, limit: 20, tagID: filtered ? tag : nil)
            #expect(first.map(\.id) == Array(expected.prefix(20).map(\.id)))
            #expect(second.map(\.id) == Array(expected.dropFirst(20).prefix(20).map(\.id)))
            let plan = try index.pageQueryPlan().joined(separator: " ")
            #expect(!plan.contains("TEMP B-TREE"))
            #expect(
                plan.contains(
                    filtered ? "SEARCH r USING COVERING INDEX relation_seek" : "SEARCH m USING INDEX meeting_seek"))
            #expect(plan.contains("(sortTime,"))
            let previous = try index.page(before: second.first, limit: 20, tagID: filtered ? tag : nil)
            #expect(previous.map(\.id) == first.map(\.id))
            #expect(try !index.pageQueryPlan().joined(separator: " ").contains("TEMP B-TREE"))
        }
    }
    @Test func rebuildDoesNotTraverseMeetingAttachments() throws {
        let (root, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = MeetingFolderStorage.folder(id: records[0].id, directory: root).appendingPathComponent(
            "attachments/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("not metadata".utf8).write(to: nested.appendingPathComponent("metadata.json"))
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        #expect(try index.count() == 45)
        #expect(index.lastRebuildErrorCount == 0)
    }

    @Test func initialIndexPublishesBatchesButRebuildKeepsCommittedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var firstID: UUID?
        for number in 0..<505 {
            let meeting = Meeting(title: "Batch \(number)")
            if firstID == nil { firstID = meeting.id }
            let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(MeetingListEntry(meeting)).write(
                to: folder.appendingPathComponent("metadata.json"))
        }
        let index = try LibraryIndex(directory: root)
        let reader = try LibraryIndex(directory: root)
        #expect(reader.requiresRebuild)
        try index.rebuild { processed in
            if processed == 500 {
                #expect(index.lastCommittedCount == 500)
                #expect((try? reader.count()) == 500)
            }
        }
        #expect(try reader.count() == 505)
        #expect(try !LibraryIndex(directory: root).requiresRebuild)
        try FileManager.default.removeItem(at: MeetingFolderStorage.folder(id: try #require(firstID), directory: root))
        try index.rebuild { processed in
            if processed == 500 {
                #expect(index.lastCommittedCount == nil)
                #expect((try? reader.count()) == 505)
            }
        }
        #expect(try reader.count() == 504)
    }

}
