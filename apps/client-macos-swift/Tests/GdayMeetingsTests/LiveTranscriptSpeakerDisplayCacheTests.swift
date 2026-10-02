import Foundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptSpeakerDisplayCacheTests {
    @MainActor
    @Test func mappingMatchesUncachedAcrossAppendCorrectionTogglesAndPeopleChanges() {
        let cache = LiveTranscriptSpeakerDisplayCache()
        var draft = LiveTranscriptResolutionCacheTests.fixture(minutes: 1)
        let person = UUID()
        draft.speakerTimeline!.speakers[0].personID = person
        var phrases = draft.resolvedRows().finalized
        let meetingID = draft.meetingID
        func check(_ enabled: Bool, _ people: Set<UUID>, id: UUID? = nil) {
            #expect(
                cache.rows(phrases, meetingID: id ?? meetingID, enabled: enabled, people: people)
                    == phrases.map { $0.displayingSpeakerLabels(enabled, knownPeople: people) })
        }
        check(true, [person])
        check(true, [person])
        #expect(cache.mappedCount == 0)
        phrases.append(.init(session: UUID(), source: .system, start: 65, end: 66, text: "Additional phrase."))
        check(true, [person])
        #expect(cache.mappedCount == 1)
        phrases[0].personID = nil
        check(true, [person])
        check(false, [person])
        check(false, [])
        check(true, [])
        check(true, [person])
        check(true, [person], id: UUID())
        #expect(cache.mappedCount == phrases.count)
    }
}
