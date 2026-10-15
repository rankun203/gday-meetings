import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct VoiceReviewNoticeTests {
    private func example(groupID: UUID = UUID()) -> VoiceExample {
        VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system", groupID: groupID)
    }

    @Test func dismissalSurvivesRelaunchAndIsScopedToLibrary() throws {
        let suite = "VoiceReviewNoticeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let examples = [example(), example()]
        let notice = VoiceReviewNotice(directory: directory, defaults: defaults)
        #expect(notice.isVisible(for: examples))
        notice.dismiss(examples: examples)
        #expect(!notice.isVisible(for: examples))
        let restored = VoiceReviewNotice(directory: directory, defaults: defaults)
        #expect(!restored.isVisible(for: examples))
        #expect(!restored.isVisible(for: Array(examples.prefix(1))))
        #expect(!restored.isVisible(for: []))
        let other = VoiceReviewNotice(directory: directory.appendingPathComponent("other"), defaults: defaults)
        #expect(other.isVisible(for: examples))
    }

    @Test func newEvidenceReopensNoticeEvenWhenVoiceCountDoesNotIncrease() throws {
        let suite = "VoiceReviewNoticeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notice = VoiceReviewNotice(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            defaults: defaults)
        let first = example()
        let added = example(groupID: first.groupID)
        notice.dismiss(examples: [first])
        #expect(VoiceReviewNotice.voiceCount(in: [first, added]) == 1)
        #expect(notice.isVisible(for: [first, added]))
        #expect(notice.isVisible(for: [added]))
        notice.dismiss(examples: [added])
        #expect(notice.dismissedExampleIDs == [added.id])
    }

    @Test func countAndVisibilityUseReviewEligibility() throws {
        let suite = "VoiceReviewNoticeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notice = VoiceReviewNotice(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            defaults: defaults)
        var confirmed = example()
        confirmed.review = .confirmed
        var excluded = example()
        excluded.excluded = true
        var cleared = example()
        cleared.manuallyCleared = true
        var assigned = example()
        assigned.personID = UUID()
        var rejected = example()
        rejected.review = .rejected
        let completed = [confirmed, excluded, cleared, assigned, rejected]
        #expect(!notice.isVisible(for: completed))
        #expect(VoiceReviewNotice.voiceCount(in: completed) == 0)
        var suggested = example()
        suggested.review = .suggested
        let pending = example()
        let examples = completed + [suggested, pending, example(groupID: pending.groupID)]
        #expect(notice.isVisible(for: examples))
        #expect(VoiceReviewNotice.voiceCount(in: examples) == 2)
        notice.dismiss(examples: examples)
        #expect(notice.dismissedExampleIDs.count == 3)
    }
}
