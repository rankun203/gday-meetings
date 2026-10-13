import Foundation
import Testing

@testable import GdayMeetings

struct SemanticFingerprintCacheTests {
    @Test func unchangedSourcesReuseProjectionAndChangedSourcesReadOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Synthetic discussion")
        meeting.summary = "- [ ] Send report"
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let cache = SemanticFingerprintCache()
        let original = try await cache.fingerprint(folder: folder)
        #expect(try await cache.fingerprint(folder: folder) == original)
        #expect(await cache.canonicalReads == 1)
        meeting.summary = "- [x] Send report"
        meeting.chat.append(.init(content: "Separate chat text"))
        try MeetingFolderStorage.write(meeting, directory: root)
        #expect(try await cache.fingerprint(folder: folder) == original)
        #expect(await cache.canonicalReads == 2)
        #expect(try await cache.fingerprint(folder: folder) == original)
        #expect(await cache.canonicalReads == 2)
        meeting.title = "Changed discussion"
        try MeetingFolderStorage.write(meeting, directory: root)
        #expect(try await cache.fingerprint(folder: folder) != original)
        #expect(await cache.canonicalReads == 3)
    }

    @Test func atomicReplacementInvalidatesEvenWithPreservedSizeAndDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "Synthetic discussion")
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: meeting.id, directory: root)
        let notes = folder.appendingPathComponent("notes.md")
        try Data("First note".utf8).write(to: notes, options: .atomic)
        let modified = try FileManager.default.attributesOfItem(atPath: notes.path)[.modificationDate]
        let cache = SemanticFingerprintCache()
        let first = try await cache.fingerprint(folder: folder)
        try Data("Other note".utf8).write(to: notes, options: .atomic)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: notes.path)
        }
        #expect(try await cache.fingerprint(folder: folder) != first)
        #expect(await cache.canonicalReads == 2)
    }

    @Test func boundedCacheEvictsLeastRecentlyUsedProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Meeting(title: "First synthetic meeting")
        let second = Meeting(title: "Second synthetic meeting")
        try MeetingFolderStorage.write(first, directory: root)
        try MeetingFolderStorage.write(second, directory: root)
        let cache = SemanticFingerprintCache(capacity: 1)
        let firstFolder = MeetingFolderStorage.folder(id: first.id, directory: root)
        _ = try await cache.fingerprint(folder: firstFolder)
        _ = try await cache.fingerprint(folder: MeetingFolderStorage.folder(id: second.id, directory: root))
        _ = try await cache.fingerprint(folder: firstFolder)
        #expect(await cache.canonicalReads == 3)
    }
}
