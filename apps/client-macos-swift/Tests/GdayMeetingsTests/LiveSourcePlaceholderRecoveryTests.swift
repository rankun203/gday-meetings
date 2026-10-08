import Foundation
import Testing

@testable import GdayMeetings

private actor SourceRecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func resolve(_ meeting: Meeting) async -> [UUID: LiveAudioSource] {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return LiveSourcePlaceholderRecovery.sources(in: meeting)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor struct LiveSourcePlaceholderRecoveryTests {
    private func fixture() -> Meeting {
        var meeting = Meeting()
        meeting.title = "Synthetic source recovery"
        meeting.liveTranscriptAdopted = true
        let id = UUID()
        meeting.transcript = [
            .init(
                id: id, start: 0, end: 1, speaker: "sys", text: "A saved passage",
                speakerID: id, source: .system, session: UUID(), sourcePlaceholder: true)
        ]
        meeting.speakers = [.init(id: id, label: "sys", track: "system", providerName: "This Mac")]
        return meeting
    }

    @Test func usesExplicitRowFlagsWithoutGuessingFromLabels() {
        var meeting = fixture()
        let id = meeting.speakers[0].id
        #expect(LiveSourcePlaceholderRecovery.sources(in: meeting) == [id: .system])
        meeting.transcript[0].sourcePlaceholder = nil
        #expect(LiveSourcePlaceholderRecovery.sources(in: meeting).isEmpty)
        meeting.transcript[0].sourcePlaceholder = false
        #expect(LiveSourcePlaceholderRecovery.sources(in: meeting).isEmpty)
        meeting.transcript[0].sourcePlaceholder = true
        meeting.speakers[0].sourcePlaceholder = .system
        #expect(LiveSourcePlaceholderRecovery.sources(in: meeting).isEmpty)
    }

    @Test func sourceRecoveryDoesNotReclassifyAScopedPassageIdentity() {
        var meeting = fixture()
        let reviewedID = UUID()
        meeting.transcript[0].speakerID = reviewedID
        meeting.speakers[0].id = reviewedID
        meeting.speakers[0].manuallyAssigned = true
        #expect(LiveSourcePlaceholderRecovery.sources(in: meeting).isEmpty)
    }

    @Test func interruptedCommitKeepsBoundaryAndTailWithoutDecodingSpeakerHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let committed = TranscriptSegment(start: 0, end: 1, text: "Committed passage")
        let tail = TranscriptSegment(start: 1, end: 2, text: "Pending passage")
        let bytes = try TranscriptStorage.encoded([committed])
        try (bytes + Data("incomplete append".utf8)).write(to: root.appendingPathComponent(TranscriptStorage.filename))
        var header: [String: Any] = [
            "version": 2, "bytes": bytes.count, "rows": 1, "finished": false,
            "segments": try JSONSerialization.jsonObject(with: JSONEncoder().encode([tail])),
            "draft": "unused recording metadata",
        ]
        let checkpoint = root.appendingPathComponent(LiveTranscriptProjection.checkpointName)
        try JSONSerialization.data(withJSONObject: header).write(to: checkpoint)
        #expect(try TranscriptStorage.read(at: root) == [committed, tail])
        header["rows"] = 2
        try JSONSerialization.data(withJSONObject: header).write(to: checkpoint)
        #expect(throws: (any Error).self) { try TranscriptStorage.read(at: root) }
        header["version"] = 99
        try JSONSerialization.data(withJSONObject: header).write(to: checkpoint)
        #expect(throws: (any Error).self) { try TranscriptStorage.read(at: root) }
    }

    @Test func adoptedMeetingLoadsWithoutDecodingCheckpointDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = fixture()
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        try MeetingFolderStorage.write(meeting, directory: root)
        let checkpoint = store.directory(for: meeting.id).appendingPathComponent(
            LiveTranscriptProjection.checkpointName)
        let checkpointData = Data(
            #"{"version":2,"bytes":0,"rows":0,"segments":[],"finished":true,"draft":"unused recording metadata"}"#.utf8)
        try checkpointData.write(to: checkpoint)
        let gate = SourceRecoveryGate()
        store.liveSourceRecovery.resolve = { await gate.resolve($0) }
        #expect(await store.ensureMeetingLoaded(id: meeting.id))
        #expect(store.meeting(id: meeting.id)?.transcript == meeting.transcript)
        let recovery = try #require(store.liveSourceRecovery.tasks[meeting.id])
        while await gate.calls == 0 { await Task.yield() }
        store.scheduleLiveSourcePlaceholderRecovery(meeting)
        #expect(await gate.calls == 1)
        // Loading has returned while the repair is deliberately still suspended.
        #expect(store.meeting(id: meeting.id)?.speakers[0].sourcePlaceholder == nil)
        var edited = try #require(store.meeting(id: meeting.id))
        edited.notes = "An edit made while recovery waits."
        #expect(await store.updateMeeting(edited))
        await gate.release()
        await recovery.value
        let saved = try MeetingFolderStorage.read(id: meeting.id, directory: root)
        #expect(saved.speakers[0].sourcePlaceholder == .system)
        #expect(saved.notes == edited.notes)
        #expect(saved.transcript == meeting.transcript)
        #expect(try Data(contentsOf: checkpoint) == checkpointData)
    }

    @Test(arguments: ["transcript", "speakers", "generation", "deleted", "recording"])
    func discardsRecoveryAfterRelevantChanges(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        let meeting = fixture()
        store.meetings = [meeting]
        let gate = SourceRecoveryGate()
        store.liveSourceRecovery.resolve = { await gate.resolve($0) }
        store.scheduleLiveSourcePlaceholderRecovery(meeting)
        let recovery = try #require(store.liveSourceRecovery.tasks[meeting.id])
        while await gate.calls == 0 { await Task.yield() }
        switch change {
        case "transcript": store.meetings[0].transcript[0].text = "A newer passage"
        case "speakers": store.meetings[0].speakers[0].label = "A reviewed label"
        case "generation": store.externalReloadGeneration = UUID()
        case "deleted": store.meetings = []
        default: store.recordingID = meeting.id
        }
        let latest = store.meetings
        await gate.release()
        await recovery.value
        #expect(store.meetings == latest)
        #expect(store.liveSourceRecovery.tasks.isEmpty)
    }

    @Test func correctSourceMetadataDoesNotWriteOrPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        var meeting = fixture()
        meeting.speakers[0].sourcePlaceholder = .system
        // Ordinary detected speakers keep nil sourcePlaceholder.
        meeting.speakers.append(.init(label: "Speaker 1", track: "system", providerName: "This Mac"))
        store.meetings = [meeting]
        store.canonicalWriteHook = { Issue.record("No repair should write to disk") }
        store.scheduleLiveSourcePlaceholderRecovery(meeting)
        let recovery = try #require(store.liveSourceRecovery.tasks[meeting.id])
        await recovery.value
        #expect(store.meetings == [meeting])
    }

    @Test func speakerLookupPreservesMetadataAndSourceRowsAcrossRetiredIdentities() {
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        let identities: [LiveSpeakerIdentity] = (0..<128).map {
            .init(id: UUID(), source: .system, generation: UUID(), slot: $0 % 8, model: "synthetic", revision: "1")
        }
        var selected = identities.last!
        selected.personID = UUID()
        selected.manuallyAssigned = true
        selected.manualReviewThrough = ["system": 10]
        selected.additionalSources = [.microphone]
        draft.speakerTimeline = .init(speakers: Array(identities.dropLast()) + [selected])
        let sourceID = UUID()
        draft.savedSegments = [
            .init(
                start: 0, end: 1, speaker: "Speaker 1", text: "Detected voice", speakerID: selected.id,
                source: .system, sourcePlaceholder: false),
            .init(
                id: sourceID, start: 2, end: 3, speaker: "mic", text: "Source passage", speakerID: sourceID,
                source: .microphone, sourcePlaceholder: true),
        ]
        let speakers = draft.speakers
        #expect(speakers.count == 2)
        #expect(speakers[0].id == selected.id)
        #expect(speakers[0].track == "multiple")
        #expect(speakers[0].personID == selected.personID)
        #expect(speakers[0].manuallyAssigned == true)
        #expect(speakers[0].manualReviewThrough == selected.manualReviewThrough)
        #expect(speakers[1].id == sourceID)
        #expect(speakers[1].sourcePlaceholder == .microphone)
    }
}
