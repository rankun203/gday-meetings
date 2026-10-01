import Foundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptEditingTests {
    private func phrase(_ session: UUID, start: Double, words: [String], source: LiveAudioSource = .microphone)
        -> LiveTranscriptPhrase
    {
        .init(
            session: session, source: source, start: start, end: start + Double(words.count),
            text: words.joined(separator: " "),
            words: words.enumerated().map {
                .init(text: $0.element, start: start + Double($0.offset), end: start + Double($0.offset + 1))
            })
    }

    @Test func stableIdentityFollowsRangeWithinSourceAndSession() {
        let session = UUID()
        let first = phrase(session, start: 0, words: ["First"])
        let replacement = phrase(session, start: 0, words: ["First", "revision"])
        let partials = LiveTranscriptPhrase.replacingPartials([first], with: replacement, final: false)
        #expect(partials.first?.id == first.id)
        #expect(replacement.preservingIdentity(from: [first]).id == first.id)
        let differentSource = phrase(session, start: 0, words: ["Remote"], source: .system)
        #expect(differentSource.preservingIdentity(from: [first]).id == differentSource.id)
        let differentSession = phrase(UUID(), start: 0, words: ["New"])
        #expect(differentSession.preservingIdentity(from: [first]).id == differentSession.id)
    }

    @Test func manualRangesSurviveMergedAndSplitRecognitionWithoutNamingOtherRows() throws {
        let session = UUID()
        let person = UUID()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let first = phrase(session, start: 0, words: ["First", "words"])
        let second = phrase(session, start: 2, words: ["Middle", "words"])
        draft.accept(first)
        draft.accept(second)
        draft.updateText("My correction", for: first)
        draft.assignPerson(person, for: first)
        draft.updateText("Second correction", for: second)
        draft.accept(phrase(session, start: 0, words: ["New", "first", "New", "second", "Keep", "ending"]))
        let merged = draft.resolvedRows().finalized
        #expect(merged.map(\.text) == ["My correction", "Second correction", "Keep ending"])
        #expect(merged.map(\.id).prefix(2) == [first.id, second.id])
        #expect(merged.first?.personID == person)
        #expect(merged.dropFirst().allSatisfy { $0.personID == nil })
        #expect(draft.phrases.first?.text == "New first New second Keep ending")
        draft.accept(phrase(session, start: 0, words: ["Split", "first"]))
        draft.accept(phrase(session, start: 2, words: ["Split", "second"]))
        #expect(draft.resolvedRows().finalized.map(\.text) == ["My correction", "Second correction"])
        let encoded = try JSONEncoder().encode(draft)
        #expect(try JSONDecoder().decode(LiveTranscriptDraft.self, from: encoded) == draft)
        #expect(draft.speakers.first?.personID == person)
        #expect(draft.speakers.last?.personID == nil)
        #expect(draft.speakers.first?.id != draft.speakers.last?.id)
    }

    @Test func assignmentTracksRevisedWordsWithoutChangingItsRange() {
        let session = UUID()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let original = phrase(session, start: 0, words: ["First", "words"])
        draft.accept(original)
        draft.assignPerson(UUID(), for: original)
        draft.accept(phrase(session, start: 0, words: ["Revised"]))
        draft.accept(phrase(session, start: 1, words: ["ending"]))
        let row = draft.resolvedRows().finalized.first
        #expect(row?.id == original.id)
        #expect(row?.text == "Revised ending")
        #expect(row?.start == 0 && row?.end == 2)
    }

    @Test func missingWordTimingKeepsRawRecognitionAndManualEdit() {
        let session = UUID()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let original = phrase(session, start: 1, words: ["Middle"])
        draft.accept(original)
        draft.updateText("Edited middle", for: original)
        let revised = LiveTranscriptPhrase(
            session: session, source: .microphone, start: 0, end: 3,
            text: "New beginning middle ending")
        draft.accept(revised)
        let rows = draft.resolvedRows().finalized
        #expect(rows.count == 2)
        #expect(rows.contains { $0.text == revised.text && $0.hasUnresolvedTiming })
        #expect(rows.contains { $0.text == "Edited middle" && $0.isUserEdited })
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(draft.phrases.first?.text == revised.text)
    }

    @Test func personOnlyOverrideKeepsLatestUntimedRecognition() {
        let session = UUID()
        let person = UUID()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let pending = LiveTranscriptPhrase(
            session: session, source: .system, start: 0, end: 2, text: "Hello", recognizedFinal: false)
        draft.assignPerson(person, for: pending)
        draft.accept(.init(session: session, source: .system, start: 0, end: 2, text: "Hello world"))
        #expect(draft.segments.first?.text == "Hello world")
        #expect(draft.speakers.first?.personID == person)
        #expect(draft.resolvedRows().finalized.first?.isUserEdited == false)
    }

    @Test func capturedAnchorSurvivesDisappearingRowWithoutExpandingEdit() {
        let session = UUID()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let anchor = phrase(session, start: 1, words: ["Original"])
        draft.accept(anchor)
        draft.accept(phrase(session, start: 0, words: ["New", "merged", "ending"]))
        draft.updateText("Edited", for: anchor)
        #expect(draft.resolvedRows().finalized.map(\.text) == ["New", "Edited", "ending"])
        #expect(draft.overrides?.first?.anchor.start == 1)
        #expect(draft.overrides?.first?.anchor.end == 2)
        draft.updateText("", for: anchor)
        #expect(draft.segments.map(\.text) == ["New", "ending"])
    }

    @Test func assigningPartialDoesNotPromoteItButExplicitTextEditIsDurable() throws {
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        var partial = phrase(UUID(), start: 0, words: ["Still", "recognizing"])
        partial.recognizedFinal = false
        draft.assignPerson(UUID(), for: partial)
        #expect(draft.resolvedRows(partials: [partial]).finalized.isEmpty)
        #expect(draft.resolvedRows(partials: [partial]).partials.count == 1)
        #expect(draft.segments.isEmpty)
        draft.updateText("Saved by the editor", for: partial)
        let row = try #require(draft.resolvedRows().finalized.first)
        #expect(row.text == "Saved by the editor")
        #expect(row.isUserEdited && !row.recognitionIsFinal)
        #expect(draft.phrases.isEmpty)
        #expect(draft.segments.count == 1)
    }

    @Test func legacyCheckpointWithoutOptionalFieldsDecodes() throws {
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.accept(phrase(UUID(), start: 0, words: ["Legacy", "text"]))
        let encoded = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(LiveTranscriptDraft.self, from: encoded)
        #expect(decoded.overrides == nil)
        #expect(decoded.segments.first?.text == "Legacy text")
        #expect(decoded.resolvedRows().finalized.first?.recognitionIsFinal == true)
        #expect(decoded.resolvedRows().finalized.first?.isUserEdited == false)
    }

    @Test @MainActor func adoptionPreservesOneRowsPersonWithoutVoiceEnrollment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let meetingID = store.createMeeting(title: "Synthetic meeting")
        let personID = store.addPerson(name: "Example person")
        var draft = LiveTranscriptDraft(meetingID: meetingID, locale: "en")
        let session = UUID()
        let first = phrase(session, start: 0, words: ["First"])
        draft.accept(first)
        draft.accept(phrase(session, start: 1, words: ["Second"]))
        draft.assignPerson(personID, for: first)
        #expect(store.adoptLiveTranscript(draft))
        let saved = try #require(store.meeting(id: meetingID))
        #expect(saved.speakers.filter { $0.personID == personID }.count == 1)
        #expect(saved.speakers.filter { $0.personID == nil }.count == 1)
        #expect(saved.speakers.allSatisfy { $0.embedding == nil })
        #expect(store.people.first?.voiceSamples.isEmpty == true)
        #expect(saved.personIDs.contains(personID))
    }
}

extension LiveTranscriptEditingTests {
    @Test @MainActor func manualLiveEnrollmentPreservesTypesAndClearsReassignedContributions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let meetingID = store.createMeeting(title: "Synthetic meeting")
        let first = store.addPerson(name: "Example person")
        let second = store.addPerson(name: "Another person")
        let speaker = UUID()
        let unrelatedSpeaker = UUID()
        store.recordingID = meetingID
        let embedding = try #require(
            TypedVoiceEmbedding.normalizing(type: .community1, values: Array(repeating: 1, count: 256)))
        var otherType = EmbeddingType.community1
        otherType.modelID = "synthetic-other-model"
        let other = try #require(
            TypedVoiceEmbedding.normalizing(type: otherType, values: Array(repeating: 1, count: 256)))
        store.enrollLiveVoice(meetingID: meetingID, personID: first, speakerID: speaker, embedding: embedding)
        store.enrollLiveVoice(meetingID: meetingID, personID: first, speakerID: speaker, embedding: other)
        store.enrollLiveVoice(meetingID: meetingID, personID: first, speakerID: unrelatedSpeaker, embedding: embedding)
        #expect(store.people.first { $0.id == first }?.voiceSamples.count == 3)
        store.enrollLiveVoice(meetingID: meetingID, personID: second, speakerID: speaker, embedding: nil)
        #expect(store.people.first { $0.id == first }?.voiceSamples.map(\.speakerID) == [unrelatedSpeaker])
        store.enrollLiveVoice(meetingID: meetingID, personID: second, speakerID: speaker, embedding: embedding)
        store.enrollLiveVoice(meetingID: meetingID, personID: second, speakerID: speaker, embedding: other)
        store.enrollLiveVoice(meetingID: meetingID, personID: nil, speakerID: speaker, embedding: nil)
        #expect(store.people.first { $0.id == second }?.voiceSamples.isEmpty == true)
        #expect(store.people.first { $0.id == first }?.voiceSamples.count == 1)
    }
}

extension LiveTranscriptEditingTests {
    @Test @MainActor func recognitionWithoutLabelDisplayReportsMissingAnalysisDependency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = LiveTranscriptController()
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory,
            sources: [.microphone], sink: LiveAudioSink(), enabled: false,
            speakerLabelsEnabled: false, speakerRecognitionEnabled: true)
        #expect(controller.speakerRecognitionEnabled)
        #expect(!controller.speakerLabelsEnabled)
        #expect(controller.speakerRecognitionStatus.contains("Choose a Nemotron provider"))
        controller.setSpeakerLabelsEnabled(false)
        #expect(controller.speakerRecognitionEnabled)
        #expect(controller.speakerLabelStatus.contains("Choose a Nemotron provider"))
        controller.setSpeakerRecognitionEnabled(false)
        #expect(controller.speakerLabelStatus == "Live speaker labels are off.")
        #expect(controller.speakerRecognitionStatus == "Speaker recognition is off.")
        await controller.finish()
    }
}
