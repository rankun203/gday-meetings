import Foundation
import Testing

@testable import GdayMeetings

struct LiveCheckpointSpeakerHistoryTests {
    private func voice(generation: UUID = UUID(), slot: Int = 0) -> LiveSpeakerIdentity {
        .init(
            id: UUID(), source: .microphone, generation: generation, slot: slot,
            model: "synthetic", revision: "1")
    }

    @Test func unusedAllocationsDoNotSurviveFinalCheckpoint() throws {
        let generations = (0..<16000).map { _ in UUID() }
        let speakers = generations.flatMap { generation in
            (0..<8).map { voice(generation: generation, slot: $0) }
        }
        let references = Set(speakers.prefix(29).map(\.id))
        let gaps = [LiveTranscriptGap(source: .microphone, start: 2, end: 3, reason: "Synthetic gap")]
        let timeline = LiveSpeakerTimeline(speakers: speakers, gaps: gaps, retiredGenerations: generations)
        let compact = LiveCheckpointSpeakerHistory.compact(
            timeline, referenced: references, overrides: [], finished: true)
        #expect(Set(compact.speakers.map(\.id)) == references)
        #expect(compact.retiredGenerations?.count == 4)
        #expect(compact.gaps == gaps)
        #expect(timeline.speakers.count == 128000)
        #expect(try JSONEncoder().encode(compact).count < 15000)
    }

    @Test func reviewEvidenceAliasClosureAndActiveNamespaceAreRetained() {
        let first = voice()
        let middle = voice()
        var destination = voice()
        destination.personID = UUID()
        var reviewed = voice()
        reviewed.manuallyAssigned = true  // Explicitly unassigned is also a review.
        var evidence = voice()
        evidence.voiceEmbedding = .init(type: .community1, values: [1] + Array(repeating: 0, count: 255))
        let active = voice()
        let unused = voice()
        let timeline = LiveSpeakerTimeline(
            speakers: [first, middle, destination, reviewed, evidence, active, unused],
            cursors: [.init(source: .microphone, generation: active.generation, sequence: 1, end: 10, final: false)],
            retiredGenerations: [first.generation, middle.generation, unused.generation],
            identityAliases: [first.id: middle.id, middle.id: destination.id, unused.id: unused.id])
        let compact = LiveCheckpointSpeakerHistory.compact(
            timeline, referenced: [first.id], overrides: [], finished: false)
        #expect(
            Set(compact.speakers.map(\.id)) == [
                first.id, middle.id, destination.id, reviewed.id, evidence.id, active.id,
            ])
        #expect(compact.identityAliases == [first.id: middle.id, middle.id: destination.id])
        #expect(compact.speakers.first(where: { $0.id == evidence.id })?.voiceEmbedding == evidence.voiceEmbedding)
        #expect(compact.cursors == timeline.cursors)
        let finished = LiveCheckpointSpeakerHistory.compact(
            timeline, referenced: [first.id], overrides: [], finished: true)
        #expect(!finished.speakers.contains(where: { $0.id == active.id }))
    }

    @Test func cyclicAliasesAndUnmaterializedManualCorrectionsStayRecoverable() {
        let first = voice()
        let second = voice()
        let scoped = voice()
        let unused = voice()
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 0, end: 1,
            text: "Synthetic words", speakerIdentity: first.id)
        let override = LiveTranscriptOverride(anchor: phrase, personWasAssigned: true, scopedSpeakerIdentity: scoped.id)
        let compact = LiveCheckpointSpeakerHistory.compact(
            .init(
                speakers: [first, second, scoped, unused], identityAliases: [first.id: second.id, second.id: first.id]),
            referenced: [], overrides: [override], finished: true)
        #expect(Set(compact.speakers.map(\.id)) == [first.id, second.id, scoped.id])
        #expect(compact.identityAliases?.count == 2)
    }

    @Test func committedRowsKeepTheirMetadataAcrossAppendsAndFinalization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent("speaker-evidence.jsonl")
        let evidenceBytes = Data("Synthetic evidence must remain untouched".utf8)
        try evidenceBytes.write(to: journal)
        let first = voice()
        let second = voice()
        let unused = voice()
        let id = UUID()
        func row(_ speaker: LiveSpeakerIdentity, _ start: Double) -> LiveTranscriptPhrase {
            .init(
                session: id, source: .microphone, start: start, end: start + 1,
                text: "Synthetic sentence.", speakerIdentity: speaker.id, diarizationLabel: speaker.label)
        }
        let firstBlock = LiveTranscriptFrozenBlock(previous: nil, rows: [row(first, 0), row(second, 2)])
        let writer = LiveTranscriptProjectionStorage()
        let draft = LiveTranscriptDraft(
            meetingID: id, locale: "en",
            speakerTimeline: .init(speakers: [first, second, unused]))
        try await writer.save(draft, snapshot: .init(head: firstBlock, tail: []), at: directory)
        let before = try #require(try LiveTranscriptProjection.checkpoint(at: directory))
        #expect(Set(before.draft.speakerTimeline?.speakers.map(\.id) ?? []) == [first.id, second.id])
        let prefix = try Data(contentsOf: directory.appendingPathComponent(TranscriptStorage.filename))
        let nextBlock = LiveTranscriptFrozenBlock(previous: firstBlock, rows: [row(second, 4)])
        try await writer.save(draft, snapshot: .init(head: nextBlock, tail: []), at: directory, finished: true)
        let after = try #require(try LiveTranscriptProjection.checkpoint(at: directory))
        let rows = try TranscriptStorage.read(at: directory)
        #expect(after.version == 2 && after.finished && after.segments.isEmpty)
        #expect(after.rows == rows.count && rows.count == 3)
        #expect(rows.first?.speakerID == first.id)
        #expect(rows.allSatisfy { $0.sourcePlaceholder == false })
        #expect(Set(after.draft.speakerTimeline?.speakers.map(\.id) ?? []) == [first.id, second.id])
        let data = try Data(contentsOf: directory.appendingPathComponent(TranscriptStorage.filename))
        #expect(data.starts(with: prefix) && UInt64(data.count) == after.bytes)
        #expect(try Data(contentsOf: journal) == evidenceBytes)
        let recovered = try #require(try LiveTranscriptProjection.read(at: directory, meetingID: id))
        #expect(recovered.segments == rows)
    }
}
