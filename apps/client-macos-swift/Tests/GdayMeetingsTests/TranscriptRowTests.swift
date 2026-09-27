import SwiftUI
import Testing

@testable import GdayMeetings

struct TranscriptRowTests {
    @Test func timestampsKeepMinuteAndHourBoundaries() {
        #expect(TranscriptRow<Text>.timestamp(0) == "00:00")
        #expect(TranscriptRow<Text>.timestamp(9.9) == "00:09")
        #expect(TranscriptRow<Text>.timestamp(3599) == "59:59")
        #expect(TranscriptRow<Text>.timestamp(3600) == "01:00:00")
        #expect(TranscriptRow<Text>.timestamp(3661) == "01:01:01")
        #expect(TranscriptRow<Text>.timestamp(-1) == "00:00")
        #expect(TranscriptRow<Text>.timestamp(.infinity) == "00:00")
        #expect(TranscriptRow<Text>.timestamp(.nan) == "00:00")
    }
}
