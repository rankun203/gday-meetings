import Combine
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct VoiceSearchLifecycleTests {
    @Test func quittingCancelsVoiceIndexWorkAndAllowsLaterPreparationIfQuitIsAborted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        store.voiceSearch.rebuildSavedEmbeddings()
        #expect(store.voiceSearch.isBuilding)
        let saved = await store.finalizeForQuit()
        #expect(saved)
        #expect(!store.voiceSearch.isBuilding)
        store.voiceSearch.rebuildSavedEmbeddings()
        #expect(store.voiceSearch.isBuilding)
        await store.voiceSearch.shutdown()
        #expect(!store.voiceSearch.isBuilding)
    }

    @Test func libraryCopyIsBlockedUntilVoiceIndexWorkStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("library"))
        let target = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.canChangeLibraryFolder, ContinuousClock.now < startupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.canChangeLibraryFolder)

        var notifications = 0
        let observation = store.objectWillChange.sink { notifications += 1 }
        store.voiceSearch.rebuildSavedEmbeddings()
        #expect(store.voiceSearch.isBuilding)
        #expect(!store.canChangeLibraryFolder)
        #expect(notifications > 0)
        await store.changeLibraryFolder(to: target, copyCurrent: true)
        #expect(store.pendingLibraryFolder == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

        store.voiceSearch.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.voiceSearch.isBuilding, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.voiceSearch.isBuilding)
        #expect(store.canChangeLibraryFolder)
        #expect(notifications >= 2)
        withExtendedLifetime(observation) {}
    }
}
