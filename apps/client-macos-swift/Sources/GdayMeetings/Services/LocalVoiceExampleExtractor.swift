import AVFoundation
import Foundation
import Synchronization

/// Extracts the reviewed source range; never runs transcription or changes speaker labels.
actor LocalVoiceExampleExtractor: VoiceExampleEmbeddingExtracting {
    private var worker: VoiceEmbeddingWorker?
    func finish() async {
        let held = worker
        worker = nil
        await held?.cancel()
    }

    func extract(example: VoiceExample, directory: URL, type: EmbeddingType) async throws -> TypedVoiceEmbedding {
        guard LocalModelRegistry.descriptor(.community1).supportedEmbeddingTypes.contains(type) else {
            throw ServiceError("This voice model is not supported on this Mac.")
        }
        guard let range = example.range, range.speechDuration >= 2 - 1e-6
        else { throw ServiceError("This example needs at least two seconds of saved speech.") }
        let file = range.audioFile
        let start = range.start
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw ServiceError("The audio for this example is unavailable.")
        }
        try Task.checkCancellation()
        let samples = try Self.readSamples(url: url, spans: range.supportSpans)
        try Task.checkCancellation()
        let session: VoiceEmbeddingWorker
        if let worker {
            session = worker
        }
        else {
            let created = VoiceEmbeddingWorker()
            do { try await created.prepare(priority: .processing) }
            catch {
                await created.cancel()
                throw error
            }
            worker = created
            session = created
        }
        let result = try await session.extract(
            .init(
                start: start,
                end: range.spans == nil ? start + Double(samples.count) / 16000 : range.end, samples: samples,
                spans: range.spans),
            priority: .processing)
        guard var result, result.type == type else {
            throw ServiceError("The speech did not produce a usable voice example.")
        }
        result.provenance = range.spans == nil ? "saved-example-speech-span" : "saved-example-clean-fragments-v1"
        return result
    }

    /// Read and convert only the bounded excerpt, including for long Opus recordings.
    static func readSamples(url: URL, start: Double, end: Double) throws -> [Float] {
        guard end - start >= 2 - 1e-6 else {
            throw ServiceError("This example needs at least two seconds of saved speech.")
        }
        let samples = try readSpan(url: url, start: start, end: end)
        guard samples.count >= 32000 else {
            throw ServiceError("This example needs at least two seconds of saved speech.")
        }
        return samples
    }

    static func readSamples(url: URL, spans: [SpeakerEvidenceSpan]) throws -> [Float] {
        guard !spans.isEmpty, spans.allSatisfy(\.isValid),
            zip(spans, spans.dropFirst()).allSatisfy({ $0.end <= $1.start })
        else { throw ServiceError("The saved speech fragments are invalid.") }
        if spans.count == 1 { return try readSamples(url: url, start: spans[0].start, end: spans[0].end) }
        let duration = spans.reduce(0) { $0 + $1.end - $1.start }
        guard duration >= 2 - 1e-6, duration <= 10 + 1e-6, spans.count <= 8 else {
            throw ServiceError("This example needs two to ten seconds of saved speech in at most eight fragments.")
        }
        var samples: [Float] = []
        for span in spans {
            try Task.checkCancellation()
            samples += try readSpan(url: url, start: span.start, end: span.end)
        }
        guard samples.count >= 32000 else {
            throw ServiceError("This example needs at least two seconds of saved speech.")
        }
        return samples
    }

    private static func readSpan(url: URL, start: Double, end: Double) throws -> [Float] {
        let reader = try StreamingAudioReader.open(url)
        guard start.isFinite, end.isFinite, start >= 0, end > start,
            end <= Double(reader.totalFrames) / StreamingAudioReader.sampleRate + 0.01,
            let offset = Int64(exactly: (start * StreamingAudioReader.sampleRate).rounded())
        else { throw ServiceError("The saved speech range is outside the recording.") }
        let endFrame = Int64((min(end, start + 10) * StreamingAudioReader.sampleRate).rounded())
        let count = AVAudioFrameCount(max(0, endFrame - offset))
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
        let frames = min(160000, Int((Double(input.frameLength) * 16000 / StreamingAudioReader.sampleRate).rounded()))
        guard frames > 0, Int(output.frameLength) >= frames, let channel = output.floatChannelData?[0] else {
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
