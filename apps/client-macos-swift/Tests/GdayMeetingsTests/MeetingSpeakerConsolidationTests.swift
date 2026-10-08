import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct MeetingSpeakerConsolidationTests {
    private func evidence(_ id: String, _ local: UUID, _ start: Double, _ values: [Double]) -> SpeakerEvidenceSample {
        .init(
            id: id, source: "microphone", localSpeakerID: local.uuidString, start: start, end: start + 3,
            embedding: TypedVoiceEmbedding.normalizing(
                type: .init(
                    modelID: "synthetic", revision: "1", compatibilityVersion: "1",
                    dimension: values.count, normalization: "unitL2"), values: values)!)
    }

    private func document(_ samples: [SpeakerEvidenceSample]) -> SpeakerEvidenceDocument {
        .init(
            samples: samples,
            activity: samples.map {
                .init(source: $0.source, localSpeakerID: $0.localSpeakerID, start: $0.start, end: $0.end)
            },
            windows: [
                .init(
                    generation: "window-a", source: "microphone",
                    localSpeakerIDs: Array(Set(samples.map(\.localSpeakerID))).sorted(), publicationStart: 0,
                    observedEnd: samples.map(\.end).max() ?? 0, policyRevision: SpeakerEvidenceWindow.protectedPolicy)
            ])
    }

    private func row(_ speaker: MeetingSpeaker, _ start: Double) -> TranscriptSegment {
        .init(
            start: start, end: start + 3, speaker: speaker.label, text: "A synthetic sentence.",
            speakerID: speaker.id, source: .microphone, personID: speaker.personID)
    }

    @Test func mergedLabelsAndDistinctVoiceRepeatWithoutChangingIdentity() throws {
        let first = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "Synthetic")
        let second = MeetingSpeaker(label: "mic_02", track: "microphone", providerName: "Synthetic")
        var meeting = Meeting(title: "Synthetic consolidation")
        let third = MeetingSpeaker(label: "mic_03", track: "microphone", providerName: "Synthetic")
        meeting.speakers = [first, second, third]
        meeting.transcript = [row(first, 0), row(second, 10), row(third, 20)]
        let samples = [
            evidence("a", first.id, 0, [1, 0]), evidence("b", second.id, 10, [1, 0]),
            evidence("c", third.id, 20, [0, 1]),
        ]
        let document = document(samples)
        let result = try SpeakerConsolidation.run(document).result
        let labels = MeetingSpeakerConsolidation.labeling(result, evidence: document, meeting: meeting)
        let updated = MeetingSpeakerConsolidation.applying(labels, to: meeting)
        #expect(updated.speakers.count == 2)
        #expect(updated.transcript[0].speakerID == updated.transcript[1].speakerID)
        #expect(updated.transcript[0].speakerID != updated.transcript[2].speakerID)
        #expect(updated.transcript.map(\.text) == meeting.transcript.map(\.text))
        #expect(updated.transcript.map(\.id) == meeting.transcript.map(\.id))
        let repeatedLabels = MeetingSpeakerConsolidation.labeling(result, evidence: document, meeting: updated)
        let repeated = MeetingSpeakerConsolidation.applying(repeatedLabels, to: updated)
        #expect(repeated.transcript == updated.transcript)
        #expect(repeated.speakers == updated.speakers)
    }

    @Test func explicitAssignmentAndExplicitRemovalSurviveRegrouping() {
        let named = MeetingSpeaker(
            label: "mic_01", track: "microphone", providerName: "Synthetic", personID: UUID(), manuallyAssigned: true)
        let cleared = MeetingSpeaker(
            label: "mic_02", track: "microphone", providerName: "Synthetic", manuallyAssigned: true)
        var meeting = Meeting(title: "Synthetic corrections")
        meeting.replaceSpeakers([named, cleared])
        meeting.transcript = [row(named, 0), row(cleared, 10)]
        let replacement = MeetingSpeaker(label: "Speaker 1", track: "microphone", providerName: "Synthetic")
        let labels = LocalDiarizationResult(
            modelRevision: "synthetic",
            ranges: [
                .init(track: "microphone", label: replacement.label, start: 0, end: 13)
            ], speakers: [replacement])
        let updated = MeetingSpeakerConsolidation.applying(labels, to: meeting)
        #expect(updated.transcript == meeting.transcript)
        #expect(updated.speakers == meeting.speakers)
    }

    @Test func liveReviewProtectsObservedSpeechWithoutLockingFutureMachineAssignments() throws {
        let named = MeetingSpeaker(
            label: "Speaker 1", track: "microphone", providerName: "Live",
            personID: UUID(), manuallyAssigned: true, manualReviewThrough: ["microphone": 10])
        var meeting = Meeting(title: "Live review boundary")
        meeting.replaceSpeakers([named])
        meeting.transcript = [row(named, 0), row(named, 8), row(named, 12)]
        let replacement = MeetingSpeaker(label: "Speaker 2", track: "microphone", providerName: "Consolidation")
        let labels = LocalDiarizationResult(
            modelRevision: "synthetic",
            ranges: [.init(track: "microphone", label: replacement.label, start: 0, end: 20)],
            speakers: [replacement])
        let recovered = try JSONDecoder().decode(MeetingSpeaker.self, from: JSONEncoder().encode(named))
        #expect(recovered.manualReviewThrough == named.manualReviewThrough)
        let updated = MeetingSpeakerConsolidation.applying(labels, to: meeting)
        #expect(updated.transcript[0] == meeting.transcript[0])
        #expect(updated.transcript[1] == meeting.transcript[1])
        #expect(updated.transcript[2].speakerID == replacement.id)
        #expect(updated.transcript[2].personID == nil)
    }

    @Test func invalidEvidenceAndUnsampledActivityPreserveExistingLabels() throws {
        let speaker = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "Synthetic")
        var meeting = Meeting(title: "Synthetic missing evidence")
        meeting.speakers = [speaker]
        meeting.transcript = [row(speaker, 0)]
        var sample = evidence("invalid", speaker.id, 0, [1, 0])
        sample.embedding.type.revision = "unknown"
        let document = SpeakerEvidenceDocument(
            samples: [sample],
            activity: [
                .init(source: "microphone", localSpeakerID: speaker.id.uuidString, start: 0, end: 3)
            ])
        let result = try SpeakerConsolidation.run(document).result
        #expect(result.intervals.first?.clusterID == nil)
        let labels = MeetingSpeakerConsolidation.labeling(result, evidence: document, meeting: meeting)
        #expect(MeetingSpeakerConsolidation.applying(labels, to: meeting).transcript == meeting.transcript)
    }
    @Test func speakersPanelRequiresValidVoiceEvidenceAndExcludesSourcePlaceholders() {
        var speaker = MeetingSpeaker(label: "Speaker 1", track: "microphone", providerName: "Synthetic")
        #expect(!speaker.canReviewVoice)
        speaker.voiceEmbedding = evidence("a", speaker.id, 0, [1, 0]).embedding
        #expect(speaker.canReviewVoice)
        speaker.sourcePlaceholder = .microphone
        #expect(!speaker.canReviewVoice)
        speaker.sourcePlaceholder = nil
        speaker.voiceEmbedding?.type.revision = "unknown"
        #expect(!speaker.canReviewVoice)
    }

    @Test func newMembershipDoesNotReuseAnExistingGroupsDisplayLabel() throws {
        let local = UUID()
        let samples = [evidence("a", local, 0, [1, 0]), evidence("b", UUID(), 10, [0, 1])]
        let document = document(samples)
        let result = try SpeakerConsolidation.run(document).result
        var meeting = Meeting(title: "Synthetic regrouping")
        let retainedID = MeetingSpeakerConsolidation.identity(meetingID: meeting.id, clusterID: result.clusters[1].id)
        meeting.speakers = [
            MeetingSpeaker(
                id: retainedID, label: "Speaker 1", track: "microphone", providerName: "Synthetic", personID: UUID())
        ]
        let labeled = MeetingSpeakerConsolidation.labeling(result, evidence: document, meeting: meeting)
        #expect(Set(labeled.speakers.map(\.label)).count == 2)
        #expect(labeled.speakers.first { $0.id == retainedID }?.label == "Speaker 1")
        #expect(labeled.speakers.first { $0.id != retainedID }?.personID == nil)
    }

    @Test func unchangedLocalGroupKeepsExistingIdentityNameAndLabel() throws {
        let old = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "Synthetic", personID: UUID())
        var meeting = Meeting(title: "Synthetic stable group")
        meeting.replaceSpeakers([old])
        meeting.transcript = [row(old, 0), row(old, 20)]
        let evidence = document([self.evidence("a", old.id, 0, [1, 0]), self.evidence("b", old.id, 20, [1, 0])])
        let result = try SpeakerConsolidation.run(evidence).result
        let labels = MeetingSpeakerConsolidation.labeling(result, evidence: evidence, meeting: meeting)
        #expect(labels.speakers.first?.id == old.id)
        #expect(labels.speakers.first?.label == old.label)
        #expect(labels.speakers.first?.personID == old.personID)
        #expect(MeetingSpeakerConsolidation.applying(labels, to: meeting).transcript == meeting.transcript)
    }

    @Test func existingIdentityReceivesUpdatedEvidenceWithoutChangingManualDecision() {
        var old = MeetingSpeaker(
            label: "Speaker 1", track: "microphone", providerName: "Synthetic", personID: UUID(), manuallyAssigned: true
        )
        old.voiceEmbedding = evidence("a", old.id, 0, [1, 0]).embedding
        var meeting = Meeting(title: "Synthetic refreshed evidence")
        meeting.replaceSpeakers([old])
        meeting.transcript = [row(old, 0)]
        var replacement = old
        replacement.voiceSampleRange = .init(audioFile: "microphone.wav", source: "microphone", start: 0, end: 3)
        replacement.personID = nil
        let result = LocalDiarizationResult(modelRevision: "synthetic", ranges: [], speakers: [replacement])
        let updated = MeetingSpeakerConsolidation.applying(result, to: meeting)
        #expect(updated.speakers.first?.voiceSampleRange == replacement.voiceSampleRange)
        #expect(updated.speakers.first?.personID == old.personID)
        #expect(updated.transcript == meeting.transcript)
    }

    @Test func unresolvedCapacityTailPreventsWholeRowReassignmentAndSurvivesResultPersistence() throws {
        let old = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "Synthetic")
        var meeting = Meeting(title: "Synthetic capacity boundary")
        meeting.replaceSpeakers([old])
        meeting.transcript = [
            .init(
                start: 0, end: 10, speaker: old.label, text: "A synthetic sentence.",
                speakerID: old.id, source: .microphone)
        ]
        let sample = evidence("a", old.id, 0, [1, 0])
        let result = SpeakerConsolidationResult(
            clusters: [
                .init(
                    id: "candidate", model: sample.model, sampleIDs: [sample.id], representativeSampleIDs: [sample.id])
            ],
            intervals: [
                .init(
                    source: "microphone", localSpeakerID: old.id.uuidString, start: 0, end: 6, clusterID: "candidate"),
                .init(
                    source: "microphone", localSpeakerID: old.id.uuidString, start: 6, end: 10,
                    unresolvedReason: "Outside a trusted speaker window"),
            ], rejectedSampleIDs: [])
        let labeling = MeetingSpeakerConsolidation.labeling(
            result, evidence: .init(samples: [sample]), meeting: meeting)
        let saved = try JSONDecoder().decode(LocalDiarizationResult.self, from: JSONEncoder().encode(labeling))
        #expect(saved.unresolvedRanges == [.init(track: "microphone", start: 6, end: 10)])
        #expect(MeetingSpeakerConsolidation.applying(saved, to: meeting).transcript == meeting.transcript)
    }

    @Test func unresolvedOtherSourceAndTouchingBoundaryDoNotBlockResolvedRows() {
        let old = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "Synthetic")
        let replacement = MeetingSpeaker(label: "Speaker 1", track: "microphone", providerName: "Synthetic")
        var meeting = Meeting(title: "Synthetic source boundaries")
        meeting.replaceSpeakers([old])
        meeting.transcript = [
            .init(
                start: 0, end: 10, speaker: old.label, text: "First synthetic sentence.", speakerID: old.id,
                source: .microphone),
            .init(
                start: 20, end: 30, speaker: old.label, text: "Second synthetic sentence.", speakerID: old.id,
                source: .microphone),
        ]
        let result = LocalDiarizationResult(
            modelRevision: "synthetic",
            ranges: [
                .init(track: "microphone", label: replacement.label, start: 0, end: 6),
                .init(track: "microphone", label: replacement.label, start: 20, end: 30),
            ], speakers: [replacement],
            unresolvedRanges: [
                .init(track: "system", start: 6, end: 10),
                .init(track: "microphone", start: 10, end: 20),
                .init(track: "microphone", start: 30, end: 35),
            ])
        let updated = MeetingSpeakerConsolidation.applying(result, to: meeting)
        #expect(updated.transcript.allSatisfy { $0.speakerID == replacement.id })
    }

    @Test func observationIdentityNeverInheritsEvenUnsplitNamedLocalTrack() throws {
        let old = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "Synthetic", personID: UUID())
        var meeting = Meeting(title: "Observation identity boundary")
        meeting.replaceSpeakers([old])
        meeting.transcript = [row(old, 0)]
        let evidence = document([self.evidence("a", old.id, 0, [1, 0])])
        let result = try SpeakerConsolidation.run(evidence).result
        let method = "observation-test-v1"
        let labels = MeetingSpeakerConsolidation.labeling(result, evidence: evidence, meeting: meeting, method: method)
        #expect(labels.modelRevision == method)
        #expect(labels.speakers.first?.id != old.id)
        #expect(labels.speakers.first?.personID == nil)
        let updated = MeetingSpeakerConsolidation.applying(labels, to: meeting)
        #expect(updated.transcript.first?.personID == nil)
        let repeated = MeetingSpeakerConsolidation.labeling(
            result, evidence: evidence, meeting: updated, method: method)
        #expect(repeated.speakers == labels.speakers)
        #expect(
            MeetingSpeakerConsolidation.identity(meetingID: meeting.id, clusterID: "a", method: method)
                != MeetingSpeakerConsolidation.identity(meetingID: meeting.id, clusterID: "a"))
    }

    @Test func observationSplitDoesNotSpreadChannelPersonAndPreservesManualRows() {
        let local = MeetingSpeaker(
            label: "mic_01", track: "microphone", providerName: "Synthetic", personID: UUID(), manuallyAssigned: true)
        var meeting = Meeting(title: "Observation split with correction")
        meeting.replaceSpeakers([local])
        meeting.transcript = [row(local, 0), row(local, 10)]
        let a = evidence("a", local.id, 0, [1, 0])
        let b = evidence("b", local.id, 10, [0, 1])
        let result = SpeakerConsolidationResult(
            clusters: [
                .init(id: "a", model: a.model, sampleIDs: [a.id], representativeSampleIDs: [a.id]),
                .init(id: "b", model: b.model, sampleIDs: [b.id], representativeSampleIDs: [b.id]),
            ],
            intervals: [
                .init(source: "microphone", localSpeakerID: local.id.uuidString, start: 0, end: 3, clusterID: "a"),
                .init(source: "microphone", localSpeakerID: local.id.uuidString, start: 10, end: 13, clusterID: "b"),
            ], rejectedSampleIDs: [])
        let labels = MeetingSpeakerConsolidation.labeling(
            result, evidence: document([a, b]), meeting: meeting, method: "observation-test-v1")
        #expect(labels.speakers.count == 2)
        #expect(labels.speakers.allSatisfy { $0.personID == nil && $0.id != local.id })
        #expect(MeetingSpeakerConsolidation.applying(labels, to: meeting).transcript == meeting.transcript)
    }

}
