import Foundation
import Testing

@testable import GdayMeetings

struct LiveSpeakerAliasTests {
    private func fixture() -> (LiveSpeakerIdentity, LiveSpeakerIdentity, LiveTranscriptPhrase, LiveSpeakerTimeline) {
        let generation = UUID()
        let shell = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: generation, slot: 0,
            model: "segmentation", revision: "1", meetingLabel: "Speaker 1")
        let voice = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: generation, slot: 0,
            model: "voice", revision: "1",
            voiceEmbedding: .init(
                type: .init(
                    modelID: "synthetic", revision: "1", compatibilityVersion: "1", dimension: 2,
                    normalization: "unitL2"), values: [1, 0]), meetingLabel: "Speaker 1")
        let phrase = LiveTranscriptPhrase(session: UUID(), source: .microphone, start: 0, end: 3, text: "Stable words")
        var timeline = LiveSpeakerTimeline()
        timeline.speakers = [shell]
        timeline.intervals = [.init(source: .microphone, speakerID: shell.id, start: 0, end: 3)]
        timeline.cursors = [.init(source: .microphone, generation: generation, sequence: 0, end: 40, final: false)]
        return (shell, voice, phrase, timeline)
    }

    @Test func sealedWordsGainCanonicalIdentityAndSurviveRecoveryAdoption() throws {
        let (shell, voice, phrase, initial) = fixture()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone])
        stream.accept(phrase, final: true)
        stream.replaceObservationTimeline(initial)
        let published = stream.frozenRow(at: 0)
        #expect(published.speakerIdentity == shell.id)
        var resolved = initial
        resolved.speakers.append(voice)
        resolved.identityAliases = [shell.id: voice.id]
        stream.replaceObservationTimeline(resolved)
        let current = stream.frozenRow(at: 0)
        #expect(current.id == published.id && current.text == published.text)
        #expect(current.start == published.start && current.end == published.end)
        #expect(current.speakerIdentity == voice.id && current.voiceEmbedding == voice.voiceEmbedding)
        #expect(stream.snapshot.phrases.first?.speakerIdentity == voice.id)
        stream.finish()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.effectivePhrases = stream.snapshot.phrases
        draft.speakerTimeline = resolved
        let recovered = try JSONDecoder().decode(LiveTranscriptDraft.self, from: JSONEncoder().encode(draft))
        #expect(recovered.speakerTimeline?.identityAliases == [shell.id: voice.id])
        #expect(recovered.segments.first?.speakerID == voice.id)
        #expect(recovered.speakers.first?.id == voice.id)
        #expect(recovered.speakers.first?.canReviewVoice == true)
    }

    @Test func explicitRemovalAndCyclicMetadataCannotAcquireAnotherName() {
        var (shell, voice, phrase, timeline) = fixture()
        shell.manuallyAssigned = true
        shell.personID = nil
        voice.personID = UUID()
        var row = phrase
        row.speakerIdentity = shell.id
        row.diarizationLabel = shell.label
        timeline.speakers = [shell, voice]
        let metadata = Dictionary(uniqueKeysWithValues: timeline.speakers.map { ($0.id, $0) })
        #expect(LiveSpeakerAliases.applying(row, aliases: [shell.id: voice.id], speakers: metadata) == row)
        #expect(LiveSpeakerAliases.resolve(shell.id, aliases: [shell.id: voice.id, voice.id: shell.id]) == shell.id)
    }
    @Test func passagePersonEditsSurviveLateAliasAndRecovery() throws {
        for reviewedPerson in [UUID(), nil] as [UUID?] {
            let (shell, originalVoice, phrase, initial) = fixture()
            var voice = originalVoice
            voice.personID = UUID()
            let stream = LiveTranscriptStream()
            stream.reset(labeling: true, sources: [.microphone])
            stream.accept(phrase, final: true)
            stream.replaceObservationTimeline(initial)
            let edit = LiveTranscriptOverride(
                anchor: stream.frozenRow(at: 0), personID: reviewedPerson, personWasAssigned: true)
            stream.updateEdits([edit], speakers: initial.speakers)
            var resolved = initial
            resolved.speakers.append(voice)
            resolved.identityAliases = [shell.id: voice.id]
            stream.replaceObservationTimeline(resolved)
            #expect(stream.frozenRow(at: 0).personID == reviewedPerson)
            var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
            draft.effectivePhrases = stream.snapshot.phrases
            draft.speakerTimeline = resolved
            draft.overrides = [edit]
            let recovered = try JSONDecoder().decode(LiveTranscriptDraft.self, from: JSONEncoder().encode(draft))
            #expect(recovered.segments.first?.personID == reviewedPerson)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try recovered.save(at: directory)
            let saved = try #require(try LiveTranscriptDraft.recover(at: directory, meetingID: recovered.meetingID))
            #expect(saved.segments.first?.personID == reviewedPerson)
        }
    }

    @Test func incrementalProjectionPreservesEditsThenRestoresRawWordsOnUndo() async throws {
        let (shell, originalVoice, phrase, initial) = fixture()
        var voice = originalVoice
        voice.personID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true, sources: [.microphone])
        var timeline = initial
        timeline.intervals = [.init(source: .microphone, speakerID: shell.id, start: 0, end: 200)]
        timeline.cursors[0].end = 0
        stream.replaceObservationTimeline(timeline)
        for index in 0..<80 {
            timeline.cursors[0].end = Double(index) + 0.5
            stream.replaceObservationTimeline(timeline)
            stream.accept(
                .init(
                    session: phrase.session, source: .microphone, start: Double(index),
                    end: Double(index) + 0.5, text: "Line \(index)"), final: true)
        }
        timeline.cursors[0].end = 120
        stream.replaceObservationTimeline(timeline)
        let storage = LiveTranscriptProjectionStorage()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.speakerTimeline = timeline
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let anchor = stream.frozenRow(at: 0)
        #expect(anchor.speakerIdentity == shell.id)
        let edit = LiveTranscriptOverride(
            anchor: anchor, text: "Reviewed words", personID: nil, personWasAssigned: true)
        draft.overrides = [edit]
        stream.updateEdits([edit], speakers: timeline.speakers)
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        stream.accept(
            .init(session: phrase.session, source: .microphone, start: 125, end: 126, text: "Later"), final: true)
        timeline.speakers.append(voice)
        timeline.identityAliases = [shell.id: voice.id]
        timeline.cursors[0].end = 170
        stream.replaceObservationTimeline(timeline)
        draft.speakerTimeline = timeline
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let edited = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: draft.meetingID))
        #expect(edited.segments.first?.text == "Reviewed words")
        #expect(edited.segments.first?.personID == nil)
        draft.overrides = []
        stream.updateEdits([], speakers: timeline.speakers)
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let undone = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: draft.meetingID))
        #expect(undone.segments.first?.text.contains("Line 0") == true)
        #expect(undone.segments.first?.text.contains("Reviewed") == false)
        #expect(undone.segments.first?.personID == voice.personID)
        #expect(undone.segments.last?.text.contains("Later") == true)
    }

}
