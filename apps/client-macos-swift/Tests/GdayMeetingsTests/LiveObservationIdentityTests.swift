import Foundation
import Testing

@testable import GdayMeetings

struct LiveObservationIdentityTests {
    private let model = EmbeddingType(
        modelID: "synthetic", revision: "1", compatibilityVersion: "1", dimension: 2, normalization: "unitL2")
    private func event(
        source: LiveAudioSource = .microphone, id: UUID, generation: UUID, sequence: Int = 0, start: Double = 0,
        end: Double = 10
    ) -> LiveSpeakerEvent {
        .init(
            source: source, generation: generation, sequence: sequence,
            speakers: [
                .init(id: id, source: source, generation: generation, slot: 0, model: "synthetic", revision: "1")
            ],
            intervals: [.init(speakerID: id, start: start, end: end)], start: start, end: end,
            continuity: .init(
                generation: generation.uuidString, source: source.rawValue, localSpeakerIDs: [id.uuidString],
                publicationStart: 0, observedEnd: end, policyRevision: SpeakerEvidenceWindow.protectedPolicy))
    }
    private func sample(_ id: String, local: UUID, source: LiveAudioSource = .microphone, start: Double = 1)
        -> SpeakerEvidenceSample
    {
        .init(
            id: id, source: source.rawValue, localSpeakerID: local.uuidString, start: start, end: start + 3,
            embedding: .init(type: model, values: [1, 0]))
    }

    @Test func twoSourcesShareMeetingIdentityWithoutSharingActivity() {
        let mic = UUID()
        let system = UUID()
        let generation = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        let accepted1 = adapter.accept(event(id: mic, generation: generation))
        #expect(accepted1)
        let accepted2 = adapter.accept(event(source: .system, id: system, generation: UUID(), start: 20, end: 30))
        #expect(accepted2)
        let a = sample("a", local: mic)
        let b = sample("b", local: system, source: .system, start: 21)
        adapter.accept(a)
        adapter.accept(b)
        let accepted3 = adapter.takeReady().count == 2
        #expect(accepted3)
        adapter.apply(
            .init(
                assignments: [.init(sampleID: "a", clusterID: "same"), .init(sampleID: "b", clusterID: "same")],
                clusters: [.init(id: "same", model: model, prototypes: [a, b])]))
        let timeline = adapter.projection(preserving: nil)
        let embedded = timeline.speakers.filter { $0.voiceEmbedding != nil }
        #expect(embedded.count == 1)
        #expect(embedded[0].includes(.microphone) && embedded[0].includes(.system))
        #expect(timeline.intervals.allSatisfy { $0.source == .microphone ? $0.end <= 10 : $0.start >= 20 })
    }

    @Test func slowSourceEvidenceIsNotPrunedByFastSourceClock() {
        let mic = UUID()
        let generation = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        let accepted4 = adapter.accept(event(id: mic, generation: generation))
        #expect(accepted4)
        let a = sample("a", local: mic)
        adapter.accept(a)
        let accepted5 = adapter.accept(event(source: .system, id: UUID(), generation: UUID(), start: 90, end: 100))
        #expect(accepted5)
        let accepted6 = adapter.takeReady().map(\.id) == ["a"]
        #expect(accepted6)
    }

    @Test func manualNamePreservedWithoutInheritingLocalPerson() {
        let id = UUID()
        let generation = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        var localEvent = event(id: id, generation: generation)
        localEvent.speakers[0].personID = UUID()
        let accepted7 = adapter.accept(localEvent)
        #expect(accepted7)
        let a = sample("a", local: id)
        adapter.accept(a)
        adapter.apply(
            .init(
                assignments: [.init(sampleID: "a", clusterID: "voice")],
                clusters: [.init(id: "voice", model: model, prototypes: [a])]))
        var timeline = adapter.projection(preserving: nil)
        let voice = timeline.speakers.first { $0.voiceEmbedding != nil }!
        #expect(voice.personID == nil)
        let person = UUID()
        timeline.assign(person, to: voice.id, manual: true)
        #expect(adapter.projection(preserving: timeline).speakers.first { $0.id == voice.id }?.personID == person)
    }

    @Test func extractionQueuePreservesFirstAndLatestAndOtherVoices() {
        var queue = LiveVoiceSampleQueue()
        let token = UUID()
        let first = UUID()
        let second = UUID()
        func audio(_ id: UUID, _ start: Double) -> LiveSpeakerAudioSample {
            .init(speakerID: id, source: .microphone, generation: token, start: start, end: start + 3, samples: [0])
        }
        let accepted8 = queue.enqueue(audio(first, 0), token: token)
        #expect(accepted8)
        let accepted9 = queue.enqueue(audio(first, 5), token: token)
        #expect(accepted9)
        let accepted10 = queue.enqueue(audio(second, 6), token: token)
        #expect(accepted10)
        let accepted11 = queue.enqueue(audio(first, 10), token: token)
        #expect(accepted11)
        #expect(queue.entries.count == 3)
        let accepted12 = queue.pop()?.sample.start == 0
        #expect(accepted12)
        let accepted13 = queue.pop()?.sample.start == 10
        #expect(accepted13)
        let accepted14 = queue.pop()?.sample.speakerID == second
        #expect(accepted14)
    }
    @Test func automaticMergePreservesConflictingManualPassages() {
        let local = UUID()
        let generation = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        let accepted15 = adapter.accept(event(id: local, generation: generation))
        #expect(accepted15)
        let a = sample("a", local: local)
        let b = sample("b", local: local, start: 6)
        adapter.accept(a)
        adapter.accept(b)
        adapter.apply(
            .init(
                assignments: [.init(sampleID: "a", clusterID: "first"), .init(sampleID: "b", clusterID: "second")],
                clusters: [
                    .init(id: "first", model: model, prototypes: [a]),
                    .init(id: "second", model: model, prototypes: [b]),
                ]))
        var before = adapter.projection(preserving: nil)
        let embedded = before.speakers.filter { $0.voiceEmbedding != nil }
        let firstID = embedded[0].id
        let secondID = embedded[1].id
        let firstPerson = UUID()
        let secondPerson = UUID()
        before.assign(firstPerson, to: firstID, manual: true)
        before.assign(secondPerson, to: secondID, manual: true)
        adapter.apply(
            .init(
                assignments: [], clusters: [.init(id: "first", model: model, prototypes: [a, b])],
                merges: [.init(fromClusterID: "second", toClusterID: "first")]))
        let after = adapter.projection(preserving: before)
        #expect(after.speakers.first { $0.id == firstID }?.personID == firstPerson)
        #expect(after.speakers.first { $0.id == secondID }?.personID == secondPerson)
        #expect(after.intervals.contains { $0.speakerID == secondID && $0.start <= 6 && $0.end >= 9 })
    }

    @Test func firstEmbeddingKeepsProvisionalAppearanceWithoutInheritingName() {
        let id = UUID()
        let generation = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        let accepted = adapter.accept(event(id: id, generation: generation))
        #expect(accepted)
        let provisional = adapter.projection(preserving: nil)
        let shell = provisional.speakers[0]
        #expect(shell.voiceEmbedding == nil)
        #expect(!provisional.intervals.isEmpty)
        let a = sample("a", local: id)
        adapter.accept(a)
        adapter.apply(
            .init(
                assignments: [.init(sampleID: "a", clusterID: "voice")],
                clusters: [.init(id: "voice", model: model, prototypes: [a])]))
        let updated = adapter.projection(preserving: provisional)
        let identified = updated.speakers.first { $0.voiceEmbedding != nil }!
        #expect(identified.id != shell.id)
        #expect(identified.label == shell.label)
        #expect(identified.colorSlot == shell.colorSlot)
        #expect(identified.personID == nil)
        #expect(adapter.provisionalAliases[shell.id] == identified.id)
    }

    @Test func queueOverflowAuditDoesNotPretendAudioIsMissing() async throws {
        var queue = LiveVoiceSampleQueue()
        let token = UUID()
        for index in 0..<queue.capacity {
            let accepted = queue.enqueue(
                .init(
                    speakerID: UUID(), source: .microphone, generation: token,
                    start: Double(index * 4), end: Double(index * 4 + 3), samples: [0]), token: token)
            #expect(accepted)
        }
        let dropped = LiveSpeakerAudioSample(
            speakerID: UUID(), source: .microphone, generation: token,
            start: 200, end: 203, samples: [0])
        let accepted = queue.enqueue(dropped, token: token)
        #expect(!accepted)
        #expect(queue.entries.count == queue.capacity)
        #expect(queue.lastOmitted?.sample.speakerID == dropped.speakerID)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SpeakerEvidenceStore(directory: folder)
        let omission = SpeakerEvidenceOmission(
            source: "microphone", localSpeakerID: dropped.speakerID.uuidString,
            start: dropped.start, end: dropped.end, reason: "Voice extraction queue capacity reached")
        try await store.appendOmission(omission)
        try await store.finish()
        let document = try SpeakerEvidenceStore.read(directory: folder)
        #expect(document.extractionOmissions == [omission])
        #expect(document.activity.isEmpty && document.samples.isEmpty)
        #expect(try SpeakerEvidenceStore.isComplete(directory: folder))
    }

    @Test func manualReviewDoesNotFreezeFutureMachinePropagation() {
        let local = UUID()
        let generation = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        let accepted = adapter.accept(event(id: local, generation: generation))
        #expect(accepted)
        let a = sample("a", local: local)
        adapter.accept(a)
        adapter.apply(
            .init(
                assignments: [.init(sampleID: "a", clusterID: "first")],
                clusters: [.init(id: "first", model: model, prototypes: [a])]))
        var reviewed = adapter.projection(preserving: nil)
        let firstID = reviewed.speakers.first { $0.voiceEmbedding != nil }!.id
        let person = UUID()
        reviewed.assign(person, to: firstID, manual: true)
        #expect(reviewed.speakers.first { $0.id == firstID }?.manualReviewThrough?["microphone"] == 10)
        let advanced = adapter.accept(event(id: local, generation: generation, sequence: 1, start: 10, end: 20))
        #expect(advanced)
        let propagated = adapter.projection(preserving: reviewed)
        #expect(propagated.intervals.contains { $0.speakerID == firstID && $0.end == 20 })
        let b = sample("b", local: local, start: 14)
        adapter.accept(b)
        adapter.apply(
            .init(
                assignments: [.init(sampleID: "b", clusterID: "second")],
                clusters: [
                    .init(id: "first", model: model, prototypes: [a]),
                    .init(id: "second", model: model, prototypes: [b]),
                ]))
        let corrected = adapter.projection(preserving: propagated)
        let secondID = corrected.speakers.first { $0.voiceEmbedding != nil && $0.id != firstID }!.id
        #expect(corrected.speakers.first { $0.id == secondID }?.personID == nil)
        #expect(corrected.intervals.contains { $0.speakerID == secondID && $0.start <= 14 && $0.end >= 17 })
        #expect(!corrected.intervals.contains { $0.speakerID == firstID && $0.end > 10 })
        #expect(corrected.intervals.contains { $0.speakerID == firstID && $0.end == 10 })
    }

    @Test func projectionRetainsJustExpiredFrontierUntilItCanBeSealed() {
        let local = UUID()
        let generation = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        let first = adapter.accept(event(id: local, generation: generation, end: 0.48))
        #expect(first)
        var silence = event(id: local, generation: generation, sequence: 1, start: 0.48, end: 30)
        silence.intervals = []
        let silenceAccepted = adapter.accept(silence)
        #expect(silenceAccepted)
        let a = sample("a", local: local, start: 0)
        adapter.accept(a)
        adapter.apply(
            .init(
                assignments: [.init(sampleID: "a", clusterID: "voice")],
                clusters: [.init(id: "voice", model: model, prototypes: [a])]))
        let initial = adapter.projection(preserving: nil)
        var next = event(id: local, generation: generation, sequence: 2, start: 30, end: 30.72)
        next.intervals = []
        let advanced = adapter.accept(next)
        #expect(advanced)
        let current = adapter.projection(preserving: initial)
        #expect(current.intervals.contains { $0.start == 0 && $0.end == 0.48 })
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone])
        stream.replaceObservationTimeline(initial)
        stream.accept(.init(session: UUID(), source: .microphone, start: 0, end: 0.48, text: "First"), final: true)
        #expect(stream.frozenCount == 0)
        stream.replaceObservationTimeline(current)
        #expect(stream.frozenCount == 1)
        #expect(stream.frozenRow(at: 0).speakerIdentity != nil)
    }

    @Test func retiredAnonymousAliasesKeepMetadataWithoutRetainingVectors() {
        let local = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        let accepted = adapter.accept(event(id: local, generation: UUID()))
        #expect(accepted)
        let a = sample("a", local: local)
        let b = sample("b", local: local, start: 6)
        adapter.accept(a)
        adapter.accept(b)
        adapter.apply(
            .init(
                assignments: [.init(sampleID: "a", clusterID: "first"), .init(sampleID: "b", clusterID: "second")],
                clusters: [
                    .init(id: "first", model: model, prototypes: [a]),
                    .init(id: "second", model: model, prototypes: [b]),
                ]))
        let before = adapter.projection(preserving: nil)
        #expect(before.speakers.filter { $0.voiceEmbedding != nil }.count == 2)
        adapter.apply(
            .init(
                assignments: [], clusters: [.init(id: "first", model: model, prototypes: [a])],
                merges: [.init(fromClusterID: "second", toClusterID: "first")]))
        let after = adapter.projection(preserving: before)
        #expect(after.speakers.count == before.speakers.count)
        #expect(after.speakers.filter { $0.voiceEmbedding != nil }.count == 1)
        #expect(
            (after.identityAliases ?? [:]).allSatisfy { source, _ in
                after.speakers.first { $0.id == source }?.voiceEmbedding == nil
            })
    }

    @Test func capacityStopsChannelPropagationButKeepsDirectVoiceEvidence() {
        let local = UUID()
        var adapter = LiveObservationIdentity(meetingID: UUID())
        var saturated = event(id: local, generation: UUID())
        saturated.continuity?.capacityReachedAt = 5
        let accepted = adapter.accept(saturated)
        #expect(accepted)
        let sample = sample("after-capacity", local: local, start: 6)
        adapter.accept(sample)
        let ready = adapter.takeReady()
        #expect(ready.map(\.id) == [sample.id])
        #expect(adapter.untrustedSampleIDs(ready) == [sample.id])
        #expect(adapter.trustedActivity().allSatisfy { $0.end <= 5 })
        #expect(adapter.untrustedActivity().allSatisfy { $0.start >= 5 })
        adapter.apply(
            .init(
                assignments: [.init(sampleID: sample.id, clusterID: "fresh-voice")],
                clusters: [.init(id: "fresh-voice", model: model, prototypes: [sample])]))
        let projected = adapter.projection(preserving: nil)
        let voice = projected.speakers.first { $0.voiceEmbedding != nil }!
        let direct = projected.intervals.filter { $0.speakerID == voice.id }
        #expect(direct.count == 1)
        #expect(direct.first?.start == 6 && direct.first?.end == 9)
        #expect(projected.identityAliases?.isEmpty != false)
        #expect(!projected.intervals.contains { $0.start < 6 && $0.end > 5 })
        #expect(!projected.intervals.contains { $0.end > 9 })
    }

}
