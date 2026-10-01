import Foundation
import Testing

@testable import GdayMeetings

struct LibraryFolderChoiceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func verifiedCopyKeepsSourceAndOmitsDisposableIndex() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let meeting = source.appendingPathComponent("meetings/example")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let bytes = Data(repeating: 7, count: 100_000)
        try bytes.write(to: meeting.appendingPathComponent("audio.wav"))
        try Data("{}".utf8).write(to: meeting.appendingPathComponent("metadata.json"))
        try Data("index".utf8).write(to: source.appendingPathComponent("index.db"))
        let models = source.appendingPathComponent("LocalModels/synthetic/revision")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try bytes.write(to: models.appendingPathComponent("model.bin"))
        try LibraryFolderChoice.copyLibrary(from: source, to: target) { _ in }
        #expect(
            try Data(contentsOf: target.appendingPathComponent("LocalModels/synthetic/revision/model.bin")) == bytes)
        #expect(try Data(contentsOf: target.appendingPathComponent("meetings/example/audio.wav")) == bytes)
        #expect(try Data(contentsOf: meeting.appendingPathComponent("audio.wav")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("index.db").path))
        #expect(try LibraryFolderChoice.inspect(target, current: source) == .library)
        #expect(
            !(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".gday-copy-") })
    }
    @Test func refusesNestedAndOccupiedDestinations() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try LibraryFolderChoice.inspect(nested, current: root) }
        let other = try fixture()
        defer { try? FileManager.default.removeItem(at: other) }
        try Data("keep".utf8).write(to: other.appendingPathComponent("important.txt"))
        #expect(throws: (any Error).self) { try LibraryFolderChoice.copyLibrary(from: root, to: other) { _ in } }
        #expect(try String(contentsOf: other.appendingPathComponent("important.txt"), encoding: .utf8) == "keep")
    }
    @Test func bookmarkAndLocalIndexAreIndependentOfLibraryFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preference = try LibraryFolderPreference(url: root)
        #expect(try preference.resolve().resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        let suite = "gday-folder-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try preference.save(defaults: defaults)
        #expect(LibraryFolderPreference.load(defaults: defaults)?.path == root.path)
        let indexRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: indexRoot) }
        let index = try LibraryIndex(directory: root, indexDirectory: indexRoot)
        try index.markEmptyLibraryComplete()
        #expect(FileManager.default.fileExists(atPath: indexRoot.appendingPathComponent("index.db").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("index.db").path))
        #expect(LibraryFolderChoice.indexDirectory(for: root) != root)
        try FileManager.default.removeItem(at: root)
        #expect(throws: (any Error).self) { try preference.resolve() }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func changesDuringCopyAndCancellationLeaveDestinationUnselected() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for number in 0..<21 { try Data("original".utf8).write(to: source.appendingPathComponent("file-\(number)")) }
        #expect(throws: (any Error).self) {
            try LibraryFolderChoice.copyLibrary(from: source, to: target) { count in
                if count == 20 { try? Data("changed".utf8).write(to: source.appendingPathComponent("file-0")) }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try LibraryFolderChoice.copyLibrary(from: source, to: target) { _ in }
        }
        do {
            try await cancelled.value
            Issue.record("A cancelled copy must fail.")
        }
        catch is CancellationError {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(
            !(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".gday-copy-") })
    }

    @MainActor @Test func explicitStoreChoiceNeverChangesRegularAppPreference() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("current"))
        let standardBefore = UserDefaults.standard.data(forKey: LibraryFolderPreference.key)
        await store.changeLibraryFolder(to: target, copyCurrent: false)
        #expect(store.pendingLibraryFolder == target)
        #expect(!store.libraryWritable)
        #expect(store.folderPreferences.data != nil)
        #expect(UserDefaults.standard.data(forKey: LibraryFolderPreference.key) == standardBefore)
        store.cancelLibraryFolderChange()
        #expect(store.pendingLibraryFolder == nil)
        #expect(store.libraryWritable)
        #expect(store.folderPreferences.data == nil)
        #expect(UserDefaults.standard.data(forKey: LibraryFolderPreference.key) == standardBefore)
        await store.changeLibraryFolder(to: target, copyCurrent: true)
        #expect(store.pendingLibraryFolder == nil)
        #expect(store.folderPreferences.data == nil)
        #expect(store.libraryWritable)
        #expect(store.libraryFolderError != nil)
    }

}
