import AVFoundation
import FluidAudio
import Foundation

/// Keeps the manager's stream state across bounded file reads, matching its official file CLI.
func transcribeNemotron(audio: URL, language: String, modelRoot: URL) async throws -> AdapterResult {
    let loading = ProcessInfo.processInfo.systemUptime
    let variant = language.lowercased().hasPrefix("en") ? "latin" : "multilingual"
    let directory = modelRoot.appendingPathComponent(variant).appendingPathComponent("2240ms")
    guard
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path)
    else {
        throw ComparisonError("The pinned local Nemotron variant is missing.")
    }
    let manager = StreamingNemotronMultilingualAsrManager()
    try await manager.loadModels(from: directory)
    do {
        await manager.setLanguage(language)
        let modelLoaded = ProcessInfo.processInfo.systemUptime
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let converter = AudioConverter()
        let blockFrames = AVAudioFrameCount(file.processingFormat.sampleRate * 60)
        let transcriptionStart = ProcessInfo.processInfo.systemUptime
        var decodeSeconds = 0.0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let decoding = ProcessInfo.processInfo.systemUptime
            let frames = min(blockFrames, AVAudioFrameCount(file.length - file.framePosition))
            guard let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
            else {
                throw ComparisonError("Couldn't allocate the next audio block.")
            }
            try file.read(into: block, frameCount: frames)
            let samples = try converter.resampleBuffer(block)
            decodeSeconds += ProcessInfo.processInfo.systemUptime - decoding
            _ = try await manager.process(samples: samples)
        }
        let result = try await manager.finishWithTokenTimings()
        let grouped = groupNemotronTimings(
            text: result.text,
            pieces: result.timings.map { .init(text: $0.token, start: $0.startTime, end: $0.endTime) },
            duration: duration)
        let transcriptionSeconds = ProcessInfo.processInfo.systemUptime - transcriptionStart
        let maximumRegression =
            zip(result.timings, result.timings.dropFirst())
            .map { max(0, $0.startTime - $1.startTime) }.max() ?? 0
        let maximumOverrun = result.timings.map { max(0, $0.endTime - duration) }.max() ?? 0
        func milliseconds(_ value: Double) -> Int {
            value.isFinite ? Int(min(value * 1000, Double(Int.max / 2)).rounded()) : -1
        }
        let stats = await manager.lastDecodeStats()
        let rescueCount = await manager.blankRescueCount
        await manager.cleanup()
        return .init(
            segments: grouped.segments.map { .init(start: $0.start, end: $0.end, text: $0.text) },
            modelID:
                "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/\(variant)/2240ms",
            modelRevision: "1a41b75758b0337ff67db7d5408280aaaf23074e",
            modelLoadSeconds: modelLoaded - loading, transcriptionSeconds: transcriptionSeconds,
            audioDecodeSeconds: decodeSeconds, timestampGranularity: grouped.granularity,
            diagnostics: [
                "decodedTokenCount": stats.tokenCount, "processedChunks": stats.processedChunks,
                "blankRescueCount": rescueCount, "timedTokenCount": result.timings.count,
                "timingValidationCode": grouped.validationCode,
                "maximumTokenStartRegressionMilliseconds": milliseconds(maximumRegression),
                "maximumTokenEndOverrunMilliseconds": milliseconds(maximumOverrun),
            ])
    }
    catch {
        await manager.cleanup()
        throw error
    }
}
