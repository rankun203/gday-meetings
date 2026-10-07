import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

private actor SpeakerEventCollector {
    var events: [LiveSpeakerEvent] = []
    var gaps: [LiveTranscriptGap] = []
    var failures: [String] = []
    func append(_ event: LiveSpeakerEvent) { events.append(event) }
    func gap(_ gap: LiveTranscriptGap) { gaps.append(gap) }
    func failure(_ message: String) { failures.append(message) }
}

struct LocalLiveDiarizationTests {
    @Test func cancelledRuntimeRejectsReplayAndFinishesWithoutModels() async {
        let runtime = LocalLiveDiarization()
        await runtime.cancel()
        await #expect(throws: CancellationError.self) {
            try await runtime.replay(samples: [Float](repeating: 0, count: 320), source: .microphone, start: 0)
        }
        #expect(!(await runtime.finish()))
        await runtime.cancel()
    }

    /// Explicit local models and synthetic speech only. Never downloads assets.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_NEMOTRON_LIVE_TEST"] == "1"))
    @MainActor func pacedSyntheticTwoSourceRuntime() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelRoot = URL(fileURLWithPath: try #require(environment["GDAY_NEMOTRON_LIVE_MODEL_DIRECTORY"]))
        let audioURL = URL(fileURLWithPath: try #require(environment["GDAY_NEMOTRON_LIVE_AUDIO"]))
        let outputRoot = URL(fileURLWithPath: try #require(environment["GDAY_NEMOTRON_LIVE_OUTPUT_ROOT"]))
        let modelID =
            LocalModelID(rawValue: environment["GDAY_NEMOTRON_LIVE_MODEL_ID"] ?? "nemotronLow") ?? .nemotronLow
        let working = outputRoot.appendingPathComponent("adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: working) }
        let manager = LocalModelManager(root: working)
        let directory = manager.modelDirectory(for: modelID)
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: modelRoot, to: directory)
        manager.verify(modelID)
        let deadline = Date().addingTimeInterval(180)
        while manager.state(for: modelID).phase != .ready && Date() < deadline {
            if manager.state(for: modelID).phase == .failed {
                Issue.record(Comment(rawValue: manager.state(for: modelID).message ?? "Model preparation failed"))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.state(for: modelID).phase == .ready)
        let collector = SpeakerEventCollector()
        let runtime = LocalLiveDiarization(manager: manager)
        let sink = LiveAudioSink()
        try await runtime.start(
            model: modelID, sources: [.microphone, .system], sink: sink,
            boundaries: [.microphone: 10, .system: 20],
            event: { await collector.append($0) }, gap: { await collector.gap($0) },
            failure: { await collector.failure($0) }, sample: { _ in })
        let file = try AVAudioFile(forReading: audioURL)
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 320))
        var frames: Int64 = 0
        let start = ContinuousClock.now
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: min(320, AVAudioFrameCount(file.length - file.framePosition)))
            let offset = Double(frames) / 16_000
            sink.append(buffer, start: 10 + offset, source: .microphone)
            sink.append(buffer, start: 20 + offset, source: .system)
            frames += Int64(buffer.frameLength)
            let scheduled = start.advanced(by: .seconds(Double(frames) / 16_000))
            try await ContinuousClock().sleep(until: scheduled)
        }
        #expect(await runtime.finish())
        let events = await collector.events
        #expect(await collector.failures.isEmpty)
        #expect(await collector.gaps.isEmpty)
        #expect(events.contains { !$0.intervals.isEmpty })
        var timeline = LiveSpeakerTimeline()
        for event in events {
            let accepted1 = timeline.accept(event)
            #expect(accepted1)
        }
        for source in LiveAudioSource.allCases {
            let cursor = try #require(timeline.cursors.first { $0.source == source })
            let origin: Double = source == .microphone ? 10 : 20
            #expect(cursor.final)
            #expect(abs(cursor.end - origin - Double(frames) / 16_000) < 0.01)
        }
        #expect(Set(timeline.speakers.map(\.id)).count == 16)
        #expect(manager.state(for: modelID).inUse == 0)
    }
}
