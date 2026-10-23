import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct UIPreviewSummaryHistoryTests {
    @Test func scenariosRequireAnExplicitSupportedArgument() {
        #expect(UIPreview.SummaryHistoryScenario.requested(arguments: []) == nil)
        #expect(UIPreview.SummaryHistoryScenario.requested(arguments: ["--synthetic-summary-history=unknown"]) == nil)
        #expect(
            UIPreview.SummaryHistoryScenario.requested(arguments: ["--synthetic-summary-history=current"]) == .current)
    }

    @Test(arguments: UIPreview.SummaryHistoryScenario.allCases)
    func fixturesExposeTheirExpectedStorageState(scenario: UIPreview.SummaryHistoryScenario) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic review")
        var meeting = try #require(store.meeting(id: id))
        meeting.summary = "Synthetic current summary"
        #expect(await store.updateMeeting(meeting))
        try UIPreview.seedSummaryHistory(store: store, meeting: meeting)
        try await UIPreview.configureSummaryHistoryScenario(store: store, meetingID: id, scenario: scenario)
        let folder = store.directory(for: id)
        switch scenario {
        case .empty, .current:
            #expect(try SummaryHistory.read(at: folder).entries.isEmpty)
            #expect(store.meeting(id: id)?.summary == (scenario == .empty ? "" : meeting.summary))
        case .error:
            #expect(throws: (any Error).self) { try SummaryHistory.read(at: folder) }
            // Verify the reader accepts a repaired fixture. UI retry is checked separately.
            try UIPreview.seedSummaryHistory(store: store, meeting: meeting)
            #expect(try SummaryHistory.read(at: folder).entries.count == 2)
        case .selectionError:
            let history = try SummaryHistory.read(at: folder)
            #expect(history.entries.count == 2)
            for entry in history.entries {
                #expect(throws: (any Error).self) { try SummaryGeneration.read(id: entry.id, at: folder) }
            }
        }
        #expect(store.managedTasks.isEmpty)
    }
}
