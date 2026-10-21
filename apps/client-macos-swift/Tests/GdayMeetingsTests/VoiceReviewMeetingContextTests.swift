import Foundation
import Testing

@testable import GdayMeetings

struct VoiceReviewMeetingContextTests {
    @Test func contextUsesLatestPendingMeetingAndAdvancesAfterReview() {
        let older = UUID()
        let newer = UUID()
        let first = VoiceExample(meetingID: older, speakerID: UUID(), source: "system")
        let second = VoiceExample(meetingID: newer, speakerID: UUID(), source: "system")
        let dates = [older: Date(timeIntervalSince1970: 10), newer: Date(timeIntervalSince1970: 20)]
        #expect(VoiceReviewMeetingContext.latestMeetingID(in: [first, second], dates: dates) == newer)
        #expect(VoiceReviewMeetingContext.latestMeetingID(in: [second, first], dates: dates) == newer)
        #expect(VoiceReviewMeetingContext.latestMeetingID(in: [first], dates: dates) == older)
        #expect(VoiceReviewMeetingContext.latestMeetingID(in: [], dates: dates) == nil)
    }

    @Test func missingDatesAndTiesRemainDeterministic() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let samples = [second, first, second].map { VoiceExample(meetingID: $0, speakerID: UUID(), source: "system") }
        #expect(VoiceReviewMeetingContext.latestMeetingID(in: samples, dates: [:]) == first)
        #expect(VoiceReviewMeetingContext.latestMeetingID(in: samples, dates: [second: .now]) == second)
    }
}
