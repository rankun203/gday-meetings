import Foundation
import Testing

@testable import GdayMeetings

struct VoiceTurnReviewSelectionTests {
    private func example(index: Int, cluster: Int = 0, duration: Double = 3) -> VoiceExample {
        let start = Double(index) * 12
        let range = VoiceSampleRange(audioFile: "system.wav", source: "system", start: start, end: start + duration)
        return .init(
            meetingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            speakerID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, source: "system",
            audioFile: range.audioFile, audioRevision: "fixture", start: range.start, end: range.end,
            embeddings: [.init(type: .community1, values: [1] + [Double](repeating: 0, count: 255))],
            origin: .discovery, detectedSpeakerID: "cluster-\(cluster)",
            attributionTurn: .init(start: range.start, end: range.end),
            sampleQuality: .init(
                policy: VoiceSampleQuality.policyVersion, range: range, audioRevision: "fixture",
                scanConfiguration: "fixture",
                sampleCount: Int(duration * 16000), nearSilentFraction: 0, fullScaleFraction: 0))
    }

    @Test func thousandsOfTurnsProvideBoundedReviewInputWithoutHiddenGroupMembers() {
        let examples = (0..<1200).map { example(index: $0, cluster: $0 % 4) }
        let selected = VoiceTurnReviewSelection.select(examples)
        #expect(selected.count == 4)
        let groups = VoiceIdentificationSelection.groups(examples)
        #expect(groups.flatMap(\.evidenceExamples).count <= 4)
        #expect(Set(groups.flatMap(\.evidenceExamples).map(\.id)).isSubset(of: Set(selected.map(\.id))))
        #expect(examples.count == 1200)
        #expect(examples.allSatisfy { $0.review == .unassigned && $0.personID == nil })
    }

    @Test func reviewedTurnPreservesItsDecisionAndAnotherIdentityCanSurface() {
        var first = example(index: 0, duration: 10)
        let second = example(index: 1, duration: 8)
        let original = VoiceTurnReviewSelection.select([first, second])
        #expect(original.map(\.id) == [first.id])
        first.review = .confirmed
        first.personID = UUID()
        let next = VoiceTurnReviewSelection.select([first, second])
        #expect(Set(next.map(\.id)) == [first.id, second.id])
        #expect(next.first(where: { $0.id == first.id })?.personID == first.personID)
        #expect(next.first(where: { $0.id == second.id })?.personID == nil)
    }

    @Test func confirmedExactAliasDoesNotHideTheNextIndependentTurn() {
        var confirmed = example(index: 0, duration: 10)
        confirmed.review = .confirmed
        confirmed.personID = UUID()
        var alias = confirmed
        alias.id = UUID()
        alias.review = .unassigned
        alias.personID = nil
        let another = example(index: 1, duration: 3)
        let selected = VoiceTurnReviewSelection.select([confirmed, alias, another])
        #expect(Set(selected.map(\.id)) == [confirmed.id, another.id])
    }

    @Test func explicitReviewAndDifferentAudioRevisionsRemainAvailable() {
        var rejected = example(index: 0)
        rejected.review = .rejected
        rejected.rejectedPersonIDs = [UUID()]
        var named = example(index: 1)
        named.namedPersonID = UUID()
        var linked = example(index: 2)
        linked.manuallyGrouped = true
        var differentRevision = example(index: 3)
        differentRevision.audioRevision = "newer-fixture"
        let ordinary = example(index: 4)
        let selected = VoiceTurnReviewSelection.select([rejected, named, linked, differentRevision, ordinary])
        #expect(selected.count == 5)
    }

    @Test func measuredUsableAudioPrecedesLongerSignalFailure() {
        let useful = example(index: 0, duration: 3)
        var silent = example(index: 1, duration: 10)
        silent.sampleQuality?.nearSilentFraction = 1
        let selected = VoiceTurnReviewSelection.select([silent, useful])
        #expect(selected.map(\.id) == [useful.id])
        let turns = [silent, useful].map {
            LocalSpeakerTurn(
                track: "track0", label: "sys_01", start: $0.start!, end: $0.end!,
                sampleRange: $0.range, audioRevision: $0.audioRevision, sampleQuality: $0.sampleQuality)
        }
        #expect(LocalSpeakerTurn.reviewRepresentative(turns)?.sampleRange == useful.range)
        #expect(LocalSpeakerTurn.reviewRepresentative([turns[0]]) == nil)
    }
}

extension VoiceTurnReviewSelectionTests {
    @Test func metadataWithoutVectorsPreservesIndependentTurnsUntilHydration() {
        let turns = (0..<3).map { index in
            var value = example(index: index)
            value.embeddings = []
            return value
        }
        #expect(VoiceTurnReviewSelection.select(turns).count == 3)
        #expect(VoiceReviewSnapshot.selectiveEvidence(turns).count == 3)
    }

    @Test func conflictingVoicesInsideDetectedClusterHaveSeparateRepresentatives() {
        var first = example(index: 0)
        var second = example(index: 1)
        first.embeddings[0].values = [1] + [Double](repeating: 0, count: 255)
        second.embeddings[0].values = [0, 1] + [Double](repeating: 0, count: 254)
        #expect(Set(VoiceTurnReviewSelection.select([first, second]).map(\.id)) == [first.id, second.id])
    }
}
