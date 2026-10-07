import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

private actor ConsolidationReplayCollector {
    var document = SpeakerEvidenceDocument()
    var generations = Set<UUID>()
    var failures: [String] = []
    var gaps: [LiveTranscriptGap] = []
    var extractionSeconds = 0.0
    var extractionFailures = 0

    func receive(_ event: LiveSpeakerEvent) {
        generations.insert(event.generation)
        if let window = event.continuity {
            do { try document.recordWindow(window) }
            catch { failures.append("Invalid speaker window provenance") }
        }
        document.activity.append(
            contentsOf: event.intervals.map {
                SpeakerEvidenceActivity(
                    source: event.source.rawValue, localSpeakerID: $0.speakerID.uuidString,
                    start: $0.start, end: $0.end)
            })
    }

    func receive(_ sample: LiveSpeakerAudioSample, extractor: CommunityVoiceEmbeddingExtractor) async {
        let started = Date()
        do {
            let values = try await extractor.extract(samples: sample.samples)
            if let embedding = TypedVoiceEmbedding.normalizing(
                type: CommunityVoiceEmbeddingExtractor.embeddingType, values: values)
            {
                document.samples.append(
                    .init(
                        id: String(format: "sample-%08d", document.samples.count), source: sample.source.rawValue,
                        localSpeakerID: sample.speakerID.uuidString, start: sample.start, end: sample.end,
                        embedding: embedding))
            }
            else {
                extractionFailures += 1
            }
        }
        catch { extractionFailures += 1 }
        extractionSeconds += Date().timeIntervalSince(started)
    }

    func failure(_ value: String) { failures.append(value) }
    func gap(_ value: LiveTranscriptGap) { gaps.append(value) }

    func write(to directory: URL, duration: Double, replaySeconds: Double, complete: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(
            to: directory.appendingPathComponent("evidence.json"), options: .withoutOverwriting)
        let started = Date()
        let result = try SpeakerConsolidation.run(document).result
        let clusteringSeconds = Date().timeIntervalSince(started)
        try encoder.encode(result).write(
            to: directory.appendingPathComponent("consolidated.json"), options: .withoutOverwriting)
        let receipt: [String: Any] = [
            "complete": complete, "durationSeconds": duration, "replaySeconds": replaySeconds,
            "clusteringSeconds": clusteringSeconds, "extractionSeconds": extractionSeconds,
            "extractionFailures": extractionFailures, "sampleCount": document.samples.count,
            "generations": generations.count, "failureCount": failures.count, "gapCount": gaps.count,
            "sampling": "production adapter; sequential awaited extraction; no controller busy skips",
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
    }
}

/// Explicit private input only. This test never downloads models or opens a user library.
struct SpeakerConsolidationReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_CONSOLIDATION_REPLAY"] == "1"))
    @MainActor func replayProductionPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        let audioURL = URL(fileURLWithPath: try #require(environment["GDAY_CONSOLIDATION_AUDIO"]))
        let output = URL(fileURLWithPath: try #require(environment["GDAY_CONSOLIDATION_OUTPUT"]))
        let data = URL(fileURLWithPath: try #require(environment["GDAY_CONSOLIDATION_DATA"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        LocalModelManager.configureShared(dataDirectory: data, available: true, migrateLegacy: false)
        let manager = LocalModelManager.shared
        let lease = try await manager.acquire(.community1, modelNames: ["FBank", "Embedding"], priority: .capture)
        let extractor = try CommunityVoiceEmbeddingExtractor(models: lease.models)
        let collector = ConsolidationReplayCollector()
        let runtime = LocalLiveDiarization(rolloverEnabled: environment["GDAY_CONSOLIDATION_ROLLOVER"] != "0")
        try await runtime.start(
            model: .nemotronLow, sources: [.microphone], sink: LiveAudioSink(), boundaries: [.microphone: 0],
            event: { await collector.receive($0) }, gap: { await collector.gap($0) },
            failure: { await collector.failure($0) },
            sample: { await collector.receive($0, extractor: extractor) })
        let file = try AVAudioFile(forReading: audioURL)
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
        var frames: AVAudioFramePosition = 0
        let started = Date()
        while frames < file.length {
            try file.read(into: buffer, frameCount: 16_000)
            guard buffer.frameLength > 0 else { break }
            let channel = try #require(buffer.floatChannelData?[0])
            let values = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            try await runtime.replay(samples: values, source: .microphone, start: Double(frames) / 16_000)
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        let complete = await runtime.finish()
        try await collector.write(
            to: output, duration: Double(frames) / 16_000, replaySeconds: Date().timeIntervalSince(started),
            complete: complete)
        manager.release(lease)
        #expect(complete)
        #expect(await collector.failures.isEmpty)
        #expect(await collector.extractionFailures == 0)
    }
}
