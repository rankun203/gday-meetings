import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct SourcePlaceholderTests {
    @Test func previewSourcesAppearWithoutAssigningAPerson() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = LiveTranscriptController()
        let person = Person(name: "Alex")
        controller.seedPreview(meetingID: UUID(), directory: root, previouslyAssignedPersonID: person.id)
        let cache = LiveTranscriptStreamDisplayCache()
        cache.update(controller.presentedStream, people: [person], enabled: false, recognitionEnabled: true)
        #expect(cache.count == 20)
        #expect(cache.row(at: 0).speaker == person.name)
        #expect(!cache.row(at: 0).canAssignPerson)
        let source = try #require(cache.phrase(id: cache.row(at: 1).id))
        controller.assignPerson(phrase: source, personID: person.id)
        #expect(controller.draft?.overrides?.isEmpty != false)
    }
    @Test func legacySpeakerWithoutSourceMarkerRemainsAssignable() throws {
        let speaker = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "This Mac")
        let data = try JSONEncoder().encode(speaker)
        #expect(!String(decoding: data, as: UTF8.self).contains("sourcePlaceholder"))
        let decoded = try JSONDecoder().decode(MeetingSpeaker.self, from: data)
        #expect(decoded.canAssignPerson)
        #expect(decoded.resolvedVoiceEmbedding == nil)
        let unidentified = MeetingSpeaker(
            label: "", track: "microphone", providerName: "This Mac", sourcePlaceholder: .microphone)
        #expect(unidentified.displayLabel.isEmpty)
        #expect(!unidentified.canAssignPerson)
    }
    @Test func sourceRowsRejectAssignmentWhileDetectedVoicesWithoutEmbeddingsAllowIt() throws {
        var phrase = LiveTranscriptPhrase(session: UUID(), source: .system, start: 0, end: 1, text: "Sample words")
        let source = LiveTranscriptDisplay.rows(finalized: [phrase], partials: [], people: [])[0]
        #expect(source.speaker == "sys")
        #expect(!source.canAssignPerson)
        phrase.speakerIdentity = UUID()
        phrase.diarizationLabel = "sys_01"
        let detected = LiveTranscriptDisplay.rows(finalized: [phrase], partials: [], people: [])[0]
        #expect(detected.speaker == "sys_01")
        #expect(detected.canAssignPerson)

        let view = NativeTranscriptView(
            rows: [source, detected], generation: 1, showsSpeakers: true, editable: true, canPlay: false,
            play: { _ in }, save: { _, _ in }, speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let cell = TranscriptNativeCell()
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        for row in [source, detected, source] {
            coordinator.configure(cell, for: row)
            #expect((cell.assignSpeaker != nil) == row.canAssignPerson)
            #expect(cell.badge.unresolved == row.canAssignPerson)
            #expect(
                (cell.menu(for: event)?.items.contains { $0.title == "Assign Person" } == true) == row.canAssignPerson)
            #expect((cell.speaker.accessibilityCustomActions()?.isEmpty == false) == row.canAssignPerson)
        }
    }

    @Test func savedSourcesKeepProvenanceAndRejectNewAssignments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        let id = await store.createMeeting(title: "Source example")
        let person = await store.addPerson(name: "Alex")
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        draft.phrases = [.init(session: UUID(), source: .microphone, start: 0, end: 1, text: "Sample words")]
        #expect(await store.adoptLiveTranscript(draft))
        let speaker = try #require(store.meeting(id: id)?.speakers.first)
        #expect(speaker.sourcePlaceholder == .microphone)
        await store.assignSpeaker(meetingID: id, speakerID: speaker.id, personID: person)
        #expect(store.meeting(id: id)?.speakers.first?.personID == nil)
        let reopened = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        #expect(await reopened.ensureMeetingLoaded(id: id))
        #expect(reopened.meeting(id: id)?.speakers.first?.sourcePlaceholder == .microphone)
    }

    @Test func legacyCheckpointRecoversSourcesWithoutGuessingFromLabelOrEmbedding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        let id = await store.createMeeting(title: "Legacy example")
        let person = await store.addPerson(name: "Alex")
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        draft.phrases = [
            .init(session: UUID(), source: .system, start: 0, end: 1, text: "First passage"),
            .init(
                session: UUID(), source: .system, start: 2, end: 3, text: "Second passage",
                speakerIdentity: UUID(), diarizationLabel: "sys_01"),
        ]
        store.recordingID = id
        try draft.save(at: store.directory(for: id))
        #expect(await store.adoptLiveTranscript(draft))
        store.recordingID = nil
        var meeting = try #require(store.meeting(id: id))
        meeting.speakers[0].sourcePlaceholder = nil
        meeting.speakers[0].label = "sys_01"
        meeting.speakers[0].personID = person
        await store.updateMeeting(meeting)
        await store.recoverUnadoptedLiveTranscript(meeting)
        let restored = try #require(store.meeting(id: id))
        #expect(restored.speakers[0].sourcePlaceholder == .system)
        #expect(restored.speakers[0].personID == person)
        #expect(restored.speakers[1].canAssignPerson)
        await store.assignSpeaker(meetingID: id, speakerID: restored.speakers[0].id, personID: nil)
        #expect(store.meeting(id: id)?.speakers[0].personID == nil)
        await store.assignSpeaker(meetingID: id, speakerID: restored.speakers[1].id, personID: person)
        #expect(store.meeting(id: id)?.speakers[1].personID == person)
    }
}
