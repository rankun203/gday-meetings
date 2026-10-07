import Foundation
import Testing

@testable import GdayMeetings

struct SpeakerConsolidationTests {
    private func sample(_ id: String, local: String, start: Double, values: [Double] = [1, 0]) -> SpeakerEvidenceSample
    {
        .init(
            id: id, source: "microphone", localSpeakerID: local, start: start, end: start + 3,
            embedding: TypedVoiceEmbedding.normalizing(
                type: .init(
                    modelID: "synthetic", revision: "1",
                    compatibilityVersion: "1", dimension: values.count, normalization: "unitL2"), values: values)!)
    }
    private func window(
        _ ids: [String], source: String = "microphone", generation: String = "first",
        start: Double = 0, end: Double = 100, capacity: Double? = nil
    ) -> SpeakerEvidenceWindow {
        .init(
            generation: generation, source: source, localSpeakerIDs: ids, publicationStart: start, observedEnd: end,
            capacityReachedAt: capacity, policyRevision: SpeakerEvidenceWindow.protectedPolicy)
    }

    @Test func trustedChannelContinuityCoversDistantActivityButNotSilenceOrUnknownLabels() throws {
        let document = SpeakerEvidenceDocument(
            samples: [sample("a", local: "one", start: 0)],
            activity: [
                .init(source: "microphone", localSpeakerID: "one", start: 0, end: 3),
                .init(source: "microphone", localSpeakerID: "one", start: 70, end: 80),
                .init(source: "microphone", localSpeakerID: "unknown", start: 85, end: 90),
            ], windows: [window(["one", "unknown"])])
        let analysis = try SpeakerConsolidation.run(document)
        #expect(analysis.result.clusters.count == 1)
        #expect(analysis.result.intervals.count == 3)
        #expect(analysis.result.intervals[1].clusterID == analysis.result.intervals[0].clusterID)
        #expect(analysis.result.intervals[2].clusterID == nil)
        #expect(analysis.audit.directSampleSpeakerSeconds == 3)
        #expect(analysis.audit.channelInferredSpeakerSeconds == 10)
        #expect(analysis.audit.unresolvedSpeakerSeconds == 5)
    }

    @Test func capacityCutRejectsCrossingSamplesAndNeverPropagatesIntoRolloverWait() throws {
        let document = SpeakerEvidenceDocument(
            samples: [
                sample("safe", local: "one", start: 0),
                sample("crossing", local: "one", start: 10), sample("late", local: "one", start: 15),
            ],
            activity: [
                .init(source: "microphone", localSpeakerID: "one", start: 0, end: 20)
            ], windows: [window(["one"], end: 20, capacity: 12)])
        let analysis = try SpeakerConsolidation.run(document)
        #expect(analysis.result.clusters.first?.sampleIDs == ["safe"])
        #expect(analysis.audit.untrustedSampleIDs == ["crossing", "late"])
        #expect(analysis.result.intervals.first?.end == 12)
        #expect(analysis.result.intervals.last?.start == 12)
        #expect(analysis.result.intervals.last?.clusterID == nil)
        #expect(analysis.audit.directSampleSpeakerSeconds + analysis.audit.channelInferredSpeakerSeconds == 12)
        #expect(analysis.audit.unresolvedSpeakerSeconds == 8)
    }

    @Test func saturatedBootstrapAndLegacyEvidenceNeverAcquireImplicitTrust() throws {
        let sample = sample("a", local: "one", start: 50)
        let activity = SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "one", start: 50, end: 60)
        let cases: [[SpeakerEvidenceWindow]?] = [nil, [window(["one"], start: 45, end: 60, capacity: 30)]]
        for windows in cases {
            let result = try SpeakerConsolidation.run(
                .init(samples: [sample], activity: [activity], windows: windows))
            #expect(result.result.clusters.isEmpty)
            #expect(result.audit.unresolvedSpeakerSeconds == 10)
        }
    }

    @Test func sameSourceOverlapPreventsMergingWhileNewWindowsCanReassociate() throws {
        let samples = [
            sample("a", local: "one", start: 0), sample("b", local: "two", start: 1),
            sample("c", local: "next", start: 20),
        ]
        let document = SpeakerEvidenceDocument(
            samples: samples,
            activity: samples.map {
                .init(source: $0.source, localSpeakerID: $0.localSpeakerID, start: $0.start, end: $0.end)
            }, windows: [window(["one", "two"], end: 10), window(["next"], generation: "next", start: 10, end: 30)])
        let result = try SpeakerConsolidation.run(document)
        #expect(result.result.clusters.count == 2)
        #expect(result.audit.cannotLinkUnitPairs == 1)
        #expect(result.result.clusters.contains { Set($0.sampleIDs) == Set(["a", "c"]) })
    }

    @Test func mixedModelsAndOtherSourceDoNotInheritChannelAssociation() throws {
        var incompatible = sample("b", local: "one", start: 5)
        incompatible.embedding.type.revision = "2"
        var otherSource = sample("c", local: "one", start: 10)
        otherSource.source = "system"
        let document = SpeakerEvidenceDocument(
            samples: [sample("a", local: "one", start: 0), incompatible, otherSource],
            activity: [
                .init(source: "microphone", localSpeakerID: "one", start: 0, end: 8),
                .init(source: "system", localSpeakerID: "one", start: 10, end: 13),
            ], windows: [window(["one"])])
        let result = try SpeakerConsolidation.run(document)
        #expect(result.result.clusters.isEmpty)
        #expect(result.audit.untrustedSampleIDs == ["a", "b", "c"])
        #expect(result.audit.unresolvedSpeakerSeconds == 11)
    }

    @Test func activityDuplicatesDoNotInflateCoverageAndCancellationStopsBeforePublication() throws {
        let activity = SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "one", start: 0, end: 3)
        let document = SpeakerEvidenceDocument(
            samples: [sample("a", local: "one", start: 0)], activity: [activity, activity],
            windows: [window(["one"])])
        let result = try SpeakerConsolidation.run(document)
        #expect(result.audit.directSampleSpeakerSeconds == 3)
        #expect(result.result.intervals.count == 1)
        #expect(throws: CancellationError.self) {
            try SpeakerConsolidation.run(document) { throw CancellationError() }
        }
    }
    @Test func membershipIdentityIsDeterministicAndChangesWithMembersOrModel() throws {
        let a = sample("a", local: "one", start: 0)
        let b = sample("b", local: "two", start: 10)
        func document(_ samples: [SpeakerEvidenceSample]) -> SpeakerEvidenceDocument {
            .init(
                samples: samples,
                activity: samples.map {
                    .init(source: $0.source, localSpeakerID: $0.localSpeakerID, start: $0.start, end: $0.end)
                }, windows: [window(["one", "two"])])
        }
        let original = try SpeakerConsolidation.run(document([a])).result
        let merged = try SpeakerConsolidation.run(document([a, b])).result
        #expect(original.clusters.first?.id != merged.clusters.first?.id)
        #expect(try SpeakerConsolidation.run(document([b, a])).result == merged)
        var changed = a
        changed.embedding.type.revision = "2"
        #expect(
            try SpeakerConsolidation.run(document([changed])).result.clusters.first?.id != original.clusters.first?.id)
    }

    @Test func overlappingSamplesCountOnlyTheirUnionWithinPublishedTrustedSpeech() throws {
        let document = SpeakerEvidenceDocument(
            samples: [
                sample("first", local: "one", start: 0),
                sample("overlap", local: "one", start: 2),
                sample("last", local: "one", start: 4),
                sample("return", local: "one", start: 12),
                sample("crossing", local: "one", start: 14),
            ],
            activity: [(1.0, 2.0), (2.5, 6.0), (7.0, 9.0), (12.0, 20.0)].map {
                .init(source: "microphone", localSpeakerID: "one", start: $0.0, end: $0.1)
            }, windows: [window(["one"], end: 20, capacity: 15)])
        let analysis = try SpeakerConsolidation.run(document)
        #expect(analysis.audit.directSampleSpeakerSeconds == 7.5)
        #expect(analysis.audit.channelInferredSpeakerSeconds == 2)
        #expect(analysis.audit.unresolvedSpeakerSeconds == 5)
        #expect(analysis.audit.untrustedSampleIDs == ["crossing"])
        #expect(analysis.result.intervals.map(\.start) == [1, 2.5, 7, 12, 15])
        #expect(analysis.result.intervals.map(\.end) == [2, 6, 9, 15, 20])
        #expect(analysis.result.intervals.dropLast().allSatisfy { $0.clusterID != nil })
        #expect(analysis.result.intervals.last?.clusterID == nil)
    }

}
