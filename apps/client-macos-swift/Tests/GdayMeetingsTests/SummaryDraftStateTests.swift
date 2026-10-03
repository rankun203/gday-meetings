import Combine
import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct SummaryDraftStateTests {
    @Test func streamingDraftsDoNotPublishLibraryChanges() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let id = UUID()
        let otherID = UUID()
        var libraryChanges = 0
        var draftChanges = 0
        let librarySubscription = store.objectWillChange.sink { libraryChanges += 1 }
        let draftSubscription = store.summaryDrafts.objectWillChange.sink { draftChanges += 1 }
        defer {
            librarySubscription.cancel()
            draftSubscription.cancel()
        }

        #expect(store.summaryDrafts.values[id] == nil)
        store.summaryDrafts.values[id] = ""
        #expect(store.summaryDrafts.values[id] == "")
        for index in 0..<100 {
            store.summaryDrafts.values[id] = "Summary fragment \(index)"
        }
        store.summaryDrafts.values[otherID] = "Another draft"
        store.summaryDrafts.values.removeValue(forKey: id)

        #expect(libraryChanges == 0)
        #expect(draftChanges == 103)
        #expect(store.summaryDrafts.values[id] == nil)
        #expect(store.summaryDrafts.values[otherID] == "Another draft")
    }
}
