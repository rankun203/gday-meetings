import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct SearchResultGroupSessionTests {
    @Test func activeMatchSurvivesLoadingAnotherPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try LibraryIndex(directory: root)
        let meetingID = UUID()
        let session = LibrarySearchSession(loadPage: { _, _, cursor, _ in
            let ids: [Int64] = cursor == 0 ? Array(1...50) : [51]
            return LibrarySearchPage(
                results: ids.map { id in
                    LibrarySearchResult(
                        id: id, meetingID: meetingID, title: "Planning", createdAt: Date(timeIntervalSince1970: 0),
                        kind: .transcript, segmentID: nil, start: Double(id), excerpt: "A planning passage.")
                }, total: 51)
        })
        #expect(session.submit("planning", index: index))
        let firstPageLoaded = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            session.displayResults.count == 50 && !session.isLoading
        }
        try #require(firstPageLoaded)
        let activeMatch = session.displayResults[12]
        session.activeMatches[meetingID] = activeMatch.id
        let generation = session.generation

        session.loadMore()

        let secondPageLoaded = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            session.displayResults.count == 51 && !session.isLoading
        }
        try #require(secondPageLoaded)
        #expect(session.generation == generation)
        #expect(session.activeMatches[meetingID] == activeMatch.id)
        #expect(SearchResultGroup.grouping(session.displayResults).first?.matches.count == 51)
    }

    @Test func newSubmissionAndPreparationClearActiveMatches() {
        let session = LibrarySearchSession()
        let meetingID = UUID()
        session.activeMatches[meetingID] = "passage:1"

        #expect(!session.submit("  ", index: nil))
        #expect(session.activeMatches[meetingID] == "passage:1")
        #expect(session.submit("planning", index: nil))
        #expect(session.activeMatches.isEmpty)

        session.activeMatches[meetingID] = "passage:2"
        #expect(session.submit("review", mode: .text, providers: []))
        #expect(session.activeMatches.isEmpty)

        session.activeMatches[meetingID] = "passage:3"
        session.beginPreparation("schedule", mode: .semantic)
        #expect(session.activeMatches.isEmpty)
    }
}
