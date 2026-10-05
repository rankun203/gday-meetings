import AVFoundation
import Foundation
import Synchronization

/// Extracts the reviewed source range; never runs transcription or changes speaker labels.
actor LocalVoiceExampleExtractor: VoiceExampleEmbeddingExtracting {
    func extract(example: VoiceExample, directory: URL, type: EmbeddingType) async throws -> TypedVoiceEmbedding {
        guard type == .community1 else { throw ServiceError("This voice model is not supported on this Mac.") }
        guard let file = example.audioFile, let start = example.start, let end = example.end,
            start.isFinite, end.isFinite, start >= 0, end - start >= 2
        else { throw ServiceError("This example needs at least two seconds of saved speech.") }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw ServiceError("The audio for this example is unavailable.")
        }
        try Task.checkCancellation()
        let samples = try Self.readSamples(url: url, start: start, end: end)
        try Task.checkCancellation()
        let worker = LiveVoiceEmbeddingWorker()
        do {
            try await worker.prepare()
            let result = try await worker.extract(
                .init(
                    speakerID: example.speakerID, source: example.source == "microphone" ? .microphone : .system,
                    generation: UUID(), start: start, end: start + Double(samples.count) / 16000, samples: samples))
            await worker.cancel()
            guard var result, result.type == type else {
                throw ServiceError("The speech did not produce a usable voice example.")
            }
            result.provenance = "saved-example-speech-span"
            return result
        }
        catch {
            await worker.cancel()
            throw error
        }
    }

    /// Read and convert only the bounded excerpt, including for long Opus recordings.
    static func readSamples(url: URL, start: Double, end: Double) throws -> [Float] {
        let reader = try StreamingAudioReader.open(url)
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 2,
            end <= Double(reader.totalFrames) / StreamingAudioReader.sampleRate + 0.01,
            let offset = Int64(exactly: (start * StreamingAudioReader.sampleRate).rounded(.down))
        else { throw ServiceError("The saved speech range is outside the recording.") }
        let count = AVAudioFrameCount(min(10, end - start) * StreamingAudioReader.sampleRate)
        guard let input = AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: count),
            let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 160064),
            let converter = AVAudioConverter(from: input.format, to: outputFormat)
        else { throw ServiceError("Couldn’t prepare the voice example audio.") }
        try reader.seek(frame: offset)
        try reader.read(into: input, frames: count)
        converter.primeMethod = .none
        // Transfer the buffer once; the converter callback owns it after taking it.
        let pendingInput = VoiceExampleConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard let next = pendingInput.take() else {
                state.pointee = .endOfStream
                return nil
            }
            state.pointee = .haveData
            return next
        }
        guard status != .error else { throw error ?? ServiceError("Couldn’t convert the voice example audio.") }
        let frames = min(160000, Int(output.frameLength))
        guard frames >= 32000, let channel = output.floatChannelData?[0] else {
            throw ServiceError("This example needs at least two seconds of saved speech.")
        }
        return Array(UnsafeBufferPointer(start: channel, count: frames))
    }

}

/// A copyable owner lets the callback transfer a non-Sendable buffer exactly once.
private final class VoiceExampleConverterInput: Sendable {
    private let buffer: Mutex<AVAudioPCMBuffer?>

    init(_ buffer: sending AVAudioPCMBuffer) { self.buffer = Mutex(buffer) }

    func take() -> sending AVAudioPCMBuffer? {
        buffer.withLock { pending in
            let value = pending
            pending = nil
            return value
        }
    }
}
