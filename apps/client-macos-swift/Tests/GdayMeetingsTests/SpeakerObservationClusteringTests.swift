import Foundation
import Testing

@testable import GdayMeetings

struct SpeakerObservationClusteringTests {
    private func sample(
        _ id: String, local: String = "one", start: Double = 0,
        values: [Double] = [1, 0]
    ) -> SpeakerEvidenceSample {
        .init(
            id: id, source: "microphone", localSpeakerID: local, start: start, end: start + 3,
            embedding: TypedVoiceEmbedding.normalizing(
                type: .init(
                    modelID: "test", revision: "1",
                    compatibilityVersion: "1", dimension: values.count, normalization: "unitL2"), values: values)!)
    }
    private func document(_ samples: [SpeakerEvidenceSample], activity: [SpeakerEvidenceActivity]? = nil)
        -> SpeakerEvidenceDocument
    {
        .init(
            samples: samples,
            activity: activity
                ?? samples.map {
                    .init(source: $0.source, localSpeakerID: $0.localSpeakerID, start: $0.start, end: $0.end)
                },
            windows: [
                .init(
                    generation: "first", source: "microphone",
                    localSpeakerIDs: Array(Set(samples.map(\.localSpeakerID))).sorted(),
                    publicationStart: 0, observedEnd: 100, policyRevision: SpeakerEvidenceWindow.protectedPolicy)
            ])
    }
    private func run(_ document: SpeakerEvidenceDocument) throws -> SpeakerConsolidation.Analysis {
        var configuration = SpeakerConsolidation.Configuration()
        configuration.observationPolicy = .init()
        configuration.maximumContinuityGap = 5
        return try SpeakerConsolidation.run(document, configuration: configuration)
    }
    @Test func reusedChannelSplitsAndFragmentsReconnect() throws {
        let samples = [
            sample("a"), sample("b", start: 20, values: [0, 1]),
            sample("b-confirm", start: 24, values: [0, 1]),
            sample("c", local: "fragment", start: 40),
        ]
        let result = try run(document(samples)).result
        #expect(result.clusters.count == 2)
        #expect(result.clusters.contains { $0.sampleIDs == ["a", "c"] })
        #expect(result.intervals[0].clusterID != result.intervals[1].clusterID)
    }
    @Test func conflictingBracketsAndDistantSpeechRemainUnresolved() throws {
        let samples = [
            sample("a"), sample("b", start: 10, values: [0, 1]),
            sample("b-confirm", start: 14, values: [0, 1]),
        ]
        let activity = [SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "one", start: 0, end: 30)]
        let result = try run(document(samples, activity: activity))
        #expect(result.result.intervals.contains { $0.start == 5 && $0.end == 8 && $0.clusterID == nil })
        #expect(result.result.intervals.last?.end == 30)
        #expect(result.result.intervals.last?.clusterID != nil)
        #expect(result.audit.directSampleSpeakerSeconds == 9)
        #expect(result.audit.channelInferredSpeakerSeconds == 18)
        #expect(result.audit.unresolvedSpeakerSeconds == 3)
    }
    @Test func activityOverlapPreventsMergingEvenWhenCleanExamplesDoNotOverlap() throws {
        let samples = [sample("a"), sample("b", local: "two", start: 8)]
        let activity = [
            SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "one", start: 0, end: 7),
            .init(source: "microphone", localSpeakerID: "two", start: 5, end: 11),
        ]
        let result = try run(document(samples, activity: activity))
        #expect(result.result.clusters.count == 2)
        #expect(result.result.intervals.allSatisfy { $0.clusterID != nil })
        #expect(result.audit.unresolvedSpeakerSeconds == 0)
    }
    @Test func modelCompatibilityLateArrivalAndCancellationAreExplicit() throws {
        var engine = SpeakerObservationClustering()
        let first = try engine.ingest(sample("late", start: 20))
        #expect(try engine.ingest(sample("earlier", start: 0)) == first)
        var changed = sample("other", start: 30)
        changed.embedding.type.revision = "2"
        #expect(try engine.ingest(changed) != first)
        let snapshot = engine.clusters.map(\.id)
        #expect(throws: CancellationError.self) {
            try engine.ingest(sample("cancel", start: 40)) { throw CancellationError() }
        }
        #expect(engine.clusters.map(\.id) == snapshot)
    }
    @Test func runnerBelowThresholdPreventsConfidentAssociation() throws {
        var engine = SpeakerObservationClustering(configuration: .init(minimumSimilarity: 0.72, minimumMargin: 0.08))
        _ = try engine.ingest(sample("a", local: "one", values: [1, 0, 0]))
        _ = try engine.ingest(sample("b", local: "two", start: 1, values: [0.5, sqrt(0.75), 0]))
        let x = 0.73
        let y = (0.71 - 0.5 * x) / sqrt(0.75)
        let value = sample("candidate", local: "third", start: 10, values: [x, y, sqrt(1 - x * x - y * y)])
        let previous = Set(engine.clusters.map(\.id))
        guard case .assigned(let id) = try engine.ingest(value) else {
            Issue.record("Missing provisional cluster")
            return
        }
        #expect(!previous.contains(id))
        #expect(engine.clusters.count == 3)
    }
    @Test func sustainedContraryVoiceSplitsFromFirstObservation() throws {
        var engine = SpeakerObservationClustering(configuration: .init(prototypeLimit: 2))
        let first = try engine.ingest(sample("a"))
        #expect(try engine.ingest(sample("b", start: 5, values: [0, 1])) == .ambiguous)
        let changed = try engine.ingest(sample("c", start: 10, values: [0, 1]))
        #expect(changed != first)
        #expect(engine.lastRevisions.contains { $0.sampleID == "b" && $0.clusterID != nil })
        #expect(engine.clusters.allSatisfy { $0.prototypes.count <= 2 })
    }
    @Test func sameSourceConstraintSurvivesPrototypeEvictionButCrossSourceCanMatch() throws {
        var engine = SpeakerObservationClustering(configuration: .init(prototypeLimit: 1))
        let first = try engine.ingest(sample("a"))
        _ = try engine.ingest(sample("b", start: 10))
        #expect(try engine.ingest(sample("overlap", local: "two", start: 1)) != first)
        var other = sample("system", start: 1)
        other.source = "system"
        // Both clusters match equally, so cross-source matching remains ambiguous,
        // rather than incorrectly adding another cannot-link constraint.
        _ = try engine.ingest(other)
        #expect(engine.cannotLinkComparisons == 1)
    }
    @Test func legacyConfigurationDecodesAndSilenceSamplesDoNotEstablishIdentity() throws {
        let config = try JSONDecoder().decode(
            SpeakerConsolidation.Configuration.self,
            from: Data(#"{"minimumSimilarity":0.72,"representativeLimit":3}"#.utf8))
        #expect(config.observationPolicy == nil)
        #expect(config.maximumContinuityGap == nil)
        let value = sample("silence")
        let result = try run(document([value], activity: []))
        #expect(result.result.clusters.isEmpty)
        #expect(result.audit.untrustedSampleIDs == ["silence"])
        #expect(result.audit.observationDiagnostics?.unsupportedActivitySampleIDs == ["silence"])
    }
    @Test func speechSupportAllowsPausesWithoutClaimingPurity() throws {
        let value = sample("pauses")
        let activity = [
            SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "one", start: 0, end: 1),
            .init(source: "microphone", localSpeakerID: "one", start: 2, end: 3),
        ]
        let result = try run(document([value], activity: activity))
        #expect(result.result.clusters.count == 1)
        #expect(result.audit.directSampleSpeakerSeconds == 2)
        #expect(result.audit.observationDiagnostics?.unsupportedActivitySampleIDs == [])
    }

    @Test func dormantTrackSurvivesSilenceAndProfileMemoryIsBounded() throws {
        var engine = SpeakerObservationClustering(configuration: .init(prototypeLimit: 3, trackLimit: 4))
        let first = try engine.ingest(sample("first"))
        #expect(try engine.ingest(sample("return", start: 300)) == first)
        for index in 0..<30 {
            _ = try engine.ingest(sample("new-\(index)", local: "local-\(index)", start: 304 + Double(index * 4)))
        }
        #expect(engine.retainedTrackCount <= 4)
        #expect(engine.retainedObservationCount <= 256)
        #expect(engine.clusters.allSatisfy { $0.prototypes.count <= 3 })
    }
    @Test func silenceDoesNotConsumeContinuitySpeechBudget() throws {
        let samples = [sample("first"), sample("return", start: 80)]
        let activity = [
            SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "one", start: 0, end: 4),
            .init(source: "microphone", localSpeakerID: "one", start: 78, end: 84),
        ]
        let result = try run(document(samples, activity: activity))
        #expect(result.audit.unresolvedSpeakerSeconds == 0)
        #expect(result.audit.channelInferredSpeakerSeconds == 4)
    }

    @Test func establishedEpochSupportsDormantContinuationOnlyInsideTrustedWindow() throws {
        let samples = [sample("first"), sample("return", start: 80)]
        let activity = [SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "one", start: 0, end: 110)]
        let result = try run(document(samples, activity: activity))
        #expect(result.result.intervals.first?.end == 100)
        #expect(result.result.intervals.first?.clusterID != nil)
        #expect(result.result.intervals.last?.clusterID == nil)
        #expect(result.audit.unresolvedSpeakerSeconds == 10)
    }

    @Test func unresolvedContraryObservationStopsEstablishedEpochContinuation() throws {
        let samples = [sample("a"), sample("a-confirm", start: 4), sample("contrary", start: 10, values: [0, 1])]
        let activity = [SpeakerEvidenceActivity(source: "microphone", localSpeakerID: "one", start: 0, end: 90)]
        let result = try run(document(samples, activity: activity))
        #expect(result.result.intervals.filter { $0.start >= 10 }.allSatisfy { $0.clusterID == nil })
        #expect(result.audit.observationDiagnostics?.ambiguousSampleIDs == ["contrary"])
    }

}
