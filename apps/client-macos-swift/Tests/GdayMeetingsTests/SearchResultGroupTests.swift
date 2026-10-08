import Foundation
import Testing

@testable import GdayMeetings

struct SearchResultGroupTests {
    @Test func emptyResultsHaveNoGroups() {
        #expect(SearchResultGroup.grouping([]).isEmpty)
    }

    @Test func interleavedMatchesKeepMeetingAndMatchRankOrder() {
        let firstMeeting = UUID()
        let secondMeeting = UUID()
        let thirdMeeting = UUID()
        let results = [
            result("first", meeting: firstMeeting),
            result("second", meeting: secondMeeting),
            result("third", meeting: firstMeeting),
            result("fourth", meeting: thirdMeeting),
            result("fifth", meeting: secondMeeting),
        ]

        let groups = SearchResultGroup.grouping(results)

        #expect(groups.map(\.id) == [firstMeeting, secondMeeting, thirdMeeting])
        #expect(groups.map(\.rank) == [1, 2, 4])
        #expect(groups.map(\.matches) == [[results[0], results[2]], [results[1], results[4]], [results[3]]])
    }

    @Test func repeatedMatchesKeepFirstPayloadWithoutRemovingOtherMeetings() {
        let firstMeeting = UUID()
        let secondMeeting = UUID()
        let original = result("same", meeting: firstMeeting, excerpt: "The first matching passage.")
        let duplicate = result("same", meeting: firstMeeting, excerpt: "A later duplicate passage.")
        let otherMeeting = result("same", meeting: secondMeeting)

        let groups = SearchResultGroup.grouping([original, duplicate, otherMeeting])

        #expect(groups.map(\.matches) == [[original], [otherMeeting]])
        #expect(groups.map(\.rank) == [1, 3])
    }

    @Test func appendingPageAddsMatchesWithoutChangingExistingMeetingOrder() {
        let firstMeeting = UUID()
        let secondMeeting = UUID()
        let newMeeting = UUID()
        let first = result("first", meeting: firstMeeting)
        let second = result("second", meeting: secondMeeting)
        let later = result("later", meeting: firstMeeting)
        let new = result("new", meeting: newMeeting)

        let initial = SearchResultGroup.grouping([first, second])
        let expanded = SearchResultGroup.grouping([first, second, second, later, new])

        #expect(Array(expanded.prefix(initial.count)).map(\.id) == initial.map(\.id))
        #expect(Array(expanded.prefix(initial.count)).map(\.rank) == initial.map(\.rank))
        #expect(expanded.map(\.matches) == [[first, later], [second], [new]])
        #expect(expanded.last?.rank == 5)
    }

    private func result(_ id: String, meeting: UUID, excerpt: String = "A matching passage.") -> SearchDisplayResult {
        SearchDisplayResult(
            id: id, meetingID: meeting, title: "Planning", excerpt: excerpt,
            createdAt: nil, passage: nil, audio: .init(filename: "audio.wav", start: 12, duration: 8))
    }
}
