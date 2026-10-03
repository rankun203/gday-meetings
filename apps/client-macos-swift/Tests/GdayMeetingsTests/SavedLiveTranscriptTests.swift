import Foundation
import Testing

@testable import GdayMeetings

struct SavedLiveTranscriptTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func append(_ range: Range<Int>, to stream: LiveTranscriptStream, session: UUID) {
        for index in range {
            stream.accept(
                .init(
                    session: session, source: .system, start: Double(index), end: Double(index + 1),
                    text: "Line \(index)."), final: true)
        }
    }

    @Test @MainActor func stabilizedPartialRowsReachDiskBeforeStop() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let controller = LiveTranscriptController()
        controller.begin(
            meetingID: id, language: "en", directory: directory,
            sources: [.system], sink: LiveAudioSink(), enabled: false)
        controller.finalizeDetachedSession(token: UUID(), work: { true }, cancel: nil)
        let token = UUID()
        controller.finalizeDetachedSession(
            token: token,
            work: {
                let words = (0..<90).map {
                    LiveTranscriptWord(text: "word\($0)", start: Double($0), end: Double($0 + 1))
                }
                controller.receive(
                    .init(
                        session: id, source: .system, start: 0, end: 90,
                        text: words.map(\.text).joined(separator: " "), words: words), final: false, token: token)
                await controller.flushCheckpoint()
                do {
                    #expect(!(try TranscriptStorage.read(at: directory)).isEmpty)
                    #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id)?.complete == false)
                }
                catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
                return true
            }, cancel: nil)
        await controller.finish()
    }

    @Test func streamedRowsSurviveInterruptedAppendAndIgnoreRawEvents() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        let storage = LiveTranscriptProjectionStorage()
        let draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        append(0..<140, to: stream, session: id)
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let rowsURL = directory.appendingPathComponent(TranscriptStorage.filename)
        let original = try Data(contentsOf: rowsURL)
        #expect(!original.isEmpty)
        #expect(try TranscriptStorage.read(at: directory).map(\.text) == (0..<140).map { "Line \($0)." })
        let handle = try FileHandle(forWritingTo: rowsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"incomplete\":".utf8))
        try handle.close()
        try Data("Invalid raw event history".utf8).write(
            to: directory.appendingPathComponent("live-transcript-events.csv"))
        #expect(try LiveTranscriptDraft.recover(at: directory, meetingID: id)?.segments.count == 140)
        append(140..<210, to: stream, session: id)
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        #expect(try Data(contentsOf: rowsURL).starts(with: original))
        #expect(try TranscriptStorage.read(at: directory).count == 210)
    }

    @Test func editsRewriteCanonicalRowsBeforeStopAndSurviveMoreAppends() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        let storage = LiveTranscriptProjectionStorage()
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        append(0..<140, to: stream, session: id)
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        draft.updateText("Edited first line.", for: stream.snapshot.phrases[0])
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        #expect(try TranscriptStorage.read(at: directory).first?.text == "Edited first line.")
        #expect(
            try String(contentsOf: directory.appendingPathComponent(TranscriptStorage.filename), encoding: .utf8)
                .contains("Edited first line."))
        append(140..<210, to: stream, session: id)
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let saved = try TranscriptStorage.read(at: directory)
        #expect(saved.count == 210)
        #expect(saved.first?.text == "Edited first line.")
        #expect(saved.last?.text == "Line 209.")
    }

    @Test func stopOnlyAppendsFinalTailAndCommitsMetadata() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        let storage = LiveTranscriptProjectionStorage()
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        append(0..<140, to: stream, session: id)
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let before = try Data(contentsOf: directory.appendingPathComponent(TranscriptStorage.filename))
        stream.finish()
        draft.complete = true
        try await storage.save(draft, snapshot: stream.snapshot, at: directory, finished: true)
        let after = try Data(contentsOf: directory.appendingPathComponent(TranscriptStorage.filename))
        #expect(after.starts(with: before))
        let checkpoint = try #require(try LiveTranscriptProjection.checkpoint(at: directory))
        #expect(checkpoint.finished && checkpoint.segments.isEmpty)
        #expect(checkpoint.rows == 140)
        #expect(checkpoint.draft.phrases.isEmpty)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id)?.complete == true)
        for name in [
            "transcript.json", "live-transcript.json", "live-transcript-segments.jsonl", "live-transcript-events.csv",
        ] {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
    }

    @Test func paragraphsContinueAcrossImmutableBlockBoundaries() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        let storage = LiveTranscriptProjectionStorage()
        let draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        for index in 0..<140 {
            stream.accept(
                .init(session: id, source: .system, start: Double(index), end: Double(index + 1), text: "word\(index)"),
                final: true)
            if index % 17 == 0 { try await storage.save(draft, snapshot: stream.snapshot, at: directory) }
        }
        stream.finish()
        try await storage.save(draft, snapshot: stream.snapshot, at: directory, finished: true)
        let actual = try TranscriptStorage.read(at: directory)
        let expected = LiveTranscriptParagraphs.groups(finalized: stream.snapshot.phrases, partials: []).map {
            TranscriptSegment(live: $0.phrase)
        }
        #expect(actual == expected)
    }

    @Test func canonicalEmptyWinsOverOldFilesAndReplacementRemovesCheckpoint() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.accept(.init(session: UUID(), source: .system, start: 1, end: 2, text: "Old passage"))
        try draft.save(at: directory)
        try Data("Invalid old transcript".utf8).write(to: directory.appendingPathComponent("live-transcript.json"))
        try TranscriptStorage.write([], at: directory)
        #expect(try TranscriptStorage.read(at: directory).isEmpty)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: draft.meetingID) == nil)
        #expect(try LiveTranscriptProjection.checkpoint(at: directory) == nil)
    }

    @Test func legacyOnlyTranscriptRequiresMigrationAndCannotReplayEvents() throws {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("Invalid event history".utf8).write(to: directory.appendingPathComponent("live-transcript-events.csv"))
        #expect(throws: (any Error).self) { try LiveTranscriptDraft.recover(at: directory, meetingID: UUID()) }
        #expect(
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent(TranscriptStorage.filename).path))
    }

    @Test func interruptedEditTransactionRestoresBothCanonicalFileAndCheckpoint() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.accept(.init(session: UUID(), source: .system, start: 1, end: 2, text: "Saved passage"))
        try draft.save(at: directory)
        var transaction = LibraryFileTransaction(root: directory)
        try transaction.remember(directory.appendingPathComponent(TranscriptStorage.filename))
        try transaction.remember(directory.appendingPathComponent(LiveTranscriptProjection.checkpointName))
        try Data("Interrupted replacement".utf8).write(to: directory.appendingPathComponent(TranscriptStorage.filename))
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(LiveTranscriptProjection.checkpointName))
        #expect(try TranscriptStorage.read(at: directory).map(\.text) == ["Saved passage"])
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: draft.meetingID)?.segments == draft.segments)
    }
    @Test func speakerAssociationAfterSealingUsesCurrentMetadata() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: true)
        var voice = LiveSpeakerIdentity(
            id: UUID(), source: .system, generation: UUID(), slot: 0, model: "synthetic", revision: "1")
        stream.accept(
            LiveSpeakerEvent(
                source: .system, generation: voice.generation, sequence: 0,
                speakers: [voice], intervals: [.init(speakerID: voice.id, start: 0, end: 150)], start: 0, end: 150))
        append(0..<140, to: stream, session: id)
        let storage = LiveTranscriptProjectionStorage()
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        draft.speakerTimeline = LiveSpeakerTimeline(speakers: [voice])
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let prefix = try Data(contentsOf: directory.appendingPathComponent(TranscriptStorage.filename))
        voice.personID = UUID()
        draft.speakerTimeline = LiveSpeakerTimeline(speakers: [voice])
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let restored = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: id))
        #expect(restored.speakers.first?.personID == voice.personID)
        #expect(try Data(contentsOf: directory.appendingPathComponent(TranscriptStorage.filename)) == prefix)
    }

    @Test @MainActor func recordingMetadataSaveAndRollbackDoNotOwnTranscriptFiles() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = store.createMeeting(title: "Synthetic recording")
        store.recordingID = id
        let folder = store.directory(for: id)
        let storage = LiveTranscriptProjectionStorage()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        append(0..<140, to: stream, session: id)
        let draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        try await storage.save(draft, snapshot: stream.snapshot, at: folder)
        let before = try Data(contentsOf: folder.appendingPathComponent(TranscriptStorage.filename))
        let checkpoint = try Data(contentsOf: folder.appendingPathComponent(LiveTranscriptProjection.checkpointName))
        var meeting = try #require(store.meeting(id: id))
        meeting.title = "Renamed recording"
        #expect(store.updateMeeting(meeting))
        #expect(try Data(contentsOf: folder.appendingPathComponent(TranscriptStorage.filename)) == before)
        #expect(
            try Data(contentsOf: folder.appendingPathComponent(LiveTranscriptProjection.checkpointName)) == checkpoint)
        // Fail the entity write after meeting documents have been written.
        let people = root.appendingPathComponent("people")
        if FileManager.default.fileExists(atPath: people.path) { try FileManager.default.removeItem(at: people) }
        try Data("Blocked entity directory".utf8).write(to: people)
        store.people.append(Person(name: "Synthetic Person"))
        meeting.title = "Uncommitted title"
        #expect(!store.updateMeeting(meeting))
        #expect(try Data(contentsOf: folder.appendingPathComponent(TranscriptStorage.filename)) == before)
        #expect(
            try Data(contentsOf: folder.appendingPathComponent(LiveTranscriptProjection.checkpointName)) == checkpoint)
        #expect(try TranscriptStorage.read(at: folder).count == 140)
        store.recordingID = nil
    }

    @Test func completeFinalObjectNeedsNoNewlineButCheckpointPrefixDoes() throws {
        let directory = directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = TranscriptSegment(start: 1, end: 2, text: "Saved text")
        let bytes = try JSONEncoder().encode(row)
        let file = directory.appendingPathComponent(TranscriptStorage.filename)
        try bytes.write(to: file)
        #expect(try TranscriptStorage.read(at: directory) == [row])
        #expect(throws: (any Error).self) { try TranscriptStorage.readRows(file, bytes: UInt64(bytes.count), count: 1) }
        try Data(bytes.dropLast()).write(to: file)
        #expect(throws: (any Error).self) { try TranscriptStorage.read(at: directory) }
    }

    @Test func missingCanonicalFileCannotSilentlyDiscardCheckpointRows() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.accept(.init(session: UUID(), source: .system, start: 1, end: 2, text: "Saved passage"))
        try draft.save(at: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(TranscriptStorage.filename))
        #expect(throws: (any Error).self) { try TranscriptStorage.read(at: directory) }
    }

}
