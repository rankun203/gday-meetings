import Foundation
import Testing

@testable import GdayMeetings

/// Recording no longer owns a speaker runtime, model lease, voice worker or
/// evidence journal. These exercise the remaining transcription lifecycle.
@MainActor struct LiveObservationLifecycleTests {
    @Test func transcriptionPublishesWithoutWaitingForSpeakerActivity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveTranscriptController()
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory, sources: [.microphone, .system],
            sink: LiveAudioSink(), enabled: false)
        let session = UUID()
        await withCheckedContinuation { continuation in
            let token = UUID()
            controller.finalizeDetachedSession(
                token: token,
                work: {
                    controller.receive(
                        .init(
                            session: session, source: .system, start: 0, end: 1,
                            text: "Published immediately."), final: true, token: token)
                    continuation.resume()
                    return true
                }, cancel: nil)
        }
        #expect(controller.presentedFinalized.map(\.text) == ["Published immediately."])
        #expect(controller.presentedFinalized.allSatisfy { !$0.hasSpeakerIdentity })
        #expect(controller.draft?.speakerTimeline == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("speaker-evidence.jsonl").path))
        await controller.finish()
        #expect(controller.draft?.segments.map(\.text) == ["Published immediately."])
        #expect(controller.draft?.speakerTimeline == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("speaker-evidence.jsonl").path))
    }

    @Test func finishPreservesExistingHistoricalEvidenceWithoutOpeningOrSealingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("speaker-evidence.jsonl")
        // Historical evidence belongs to saved recording workflows. Beginning a
        // transcription session must not validate, append to, or seal this file.
        let historical = Data("Historical evidence is owned by its saved recording.\n".utf8)
        try historical.write(to: file)
        let controller = LiveTranscriptController()
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory, sources: [.microphone],
            sink: LiveAudioSink(), enabled: false)
        await controller.finish()
        #expect(try Data(contentsOf: file) == historical)
        #expect(controller.liveTranscriptIssues.isEmpty)
        #expect(controller.draft?.speakerTimeline == nil)
    }
}
