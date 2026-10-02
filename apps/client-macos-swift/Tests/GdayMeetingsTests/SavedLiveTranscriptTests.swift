import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

struct SavedLiveTranscriptTests {
    @Test @MainActor func stabilizedPartialRowsReachDiskBeforeStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let controller = LiveTranscriptController()
        controller.begin(
            meetingID: id, language: "en", directory: directory,
            sources: [.system], sink: LiveAudioSink(), enabled: false)
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
                    let saved = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: id))
                    #expect(!saved.segments.isEmpty)
                    #expect(saved.complete == false)
                }
                catch { Issue.record(Comment(rawValue: error.localizedDescription)) }
                return true
            }, cancel: nil)
        await controller.finish()
    }

    @Test func streamedRowsSurviveInterruptedAppendAndWinOverRawEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        let storage = LiveTranscriptProjectionStorage()
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        for index in 0..<140 {
            stream.accept(
                .init(
                    session: id, source: .system, start: Double(index), end: Double(index + 1), text: "Line \(index)"),
                final: true)
        }
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let rowsURL = directory.appendingPathComponent(LiveTranscriptProjection.rowsName)
        let original = try Data(contentsOf: rowsURL)
        #expect(!original.isEmpty)
        let expected = stream.snapshot.phrases.map(\.text)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id)?.effectivePhrases?.map(\.text) == expected)

        // Simulate death after a partial append but before checkpoint publication.
        let handle = try FileHandle(forWritingTo: rowsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"incomplete\":".utf8))
        try handle.close()
        try Data("Invalid raw event history".utf8).write(
            to: directory.appendingPathComponent("live-transcript-events.csv"))
        #expect(
            try LiveTranscriptDraft.recover(at: directory, meetingID: id)?.effectivePhrases?.map(\.text) == expected)

        // Retry discards uncommitted bytes and preserves the already saved prefix.
        for index in 140..<210 {
            stream.accept(
                .init(
                    session: id, source: .system, start: Double(index), end: Double(index + 1), text: "Line \(index)"),
                final: true)
        }
        draft.updateText("Edited first line", for: stream.snapshot.phrases[0])
        try await storage.save(draft, snapshot: stream.snapshot, at: directory)
        let extended = try Data(contentsOf: rowsURL)
        #expect(extended.starts(with: original))
        let restored = try #require(try LiveTranscriptDraft.read(at: directory, meetingID: id))
        #expect(restored.effectivePhrases?.count == 210)
        #expect(restored.resolvedRows().finalized.first?.text == "Edited first line")
        #expect(restored.complete == false)
        #expect(restored.rawSpeakerPhrases?.count == 210)
    }

    @Test func completedProjectionPreservesCompletionWithoutFullSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        stream.accept(.init(session: id, source: .system, start: 0, end: 1, text: "Saved"), final: true)
        stream.finish()
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        draft.complete = true
        try await LiveTranscriptProjectionStorage().save(
            draft, snapshot: stream.snapshot, at: directory, finished: true)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id)?.complete == true)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("live-transcript.json").path))
    }

    @Test func ordinaryReadsIgnoreRecoveryEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let journal = directory.appendingPathComponent("live-transcript-events.csv")
        try Data("Invalid recovery events\n".utf8).write(to: journal)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id) == nil)
        var draft = LiveTranscriptDraft(meetingID: id, locale: "en")
        draft.accept(.init(session: UUID(), source: .system, start: 1, end: 2, text: "Saved passage"))
        try draft.save(at: directory)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id) == draft)
        #expect(throws: (any Error).self) {
            try LiveTranscriptDraft.recover(at: directory, meetingID: id)
        }
    }

    @Test func recoveredProjectionCanBeSavedWithoutReplayingAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let journalURL = directory.appendingPathComponent("live-transcript-events.csv")
        let writer = LiveTranscriptJournal<LiveTranscriptJournalRecord>.events(at: journalURL)
        writer.append(.begin(.init(meetingID: id, locale: "en"), labeling: false))
        writer.append(
            .phrase(.init(session: UUID(), source: .system, start: 1, end: 2, text: "Recovered passage"), final: true))
        writer.append(.finish)
        try await writer.flush()
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id) == nil)
        try Data("Interrupted checkpoint".utf8).write(
            to: directory.appendingPathComponent(LiveTranscriptProjection.checkpointName))
        #expect(throws: (any Error).self) { try LiveTranscriptDraft.read(at: directory, meetingID: id) }
        let recovered = try #require(try LiveTranscriptDraft.recover(at: directory, meetingID: id))
        let saved = try recovered.saveRetiringJournal(at: directory)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
        #expect(saved.committedJournalDigest != nil)
        try Data("Unreadable archived events".utf8).write(
            to: directory.appendingPathComponent("live-transcript-events.saved.csv"))
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id) == saved)
        #expect(try LiveTranscriptDraft.recover(at: directory, meetingID: id) == saved)
        #expect(saved.segments.map(\.text) == ["Recovered passage"])
    }

    @Test func chunkedDigestMatchesWholeFileIncludingEmptyAndPartialChunks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for count in [0, 1, 65536, 196625] {
            let bytes = Data((0..<count).map { UInt8($0 % 251) })
            try bytes.write(to: url)
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(try LiveTranscriptDraft.journalDigest(at: url) == expected)
        }
    }
}
