import AVFoundation
import CoreMedia
import Speech

/// File input is pulled by SpeechAnalyzer without the bounded live-capture queue.
/// Each recording track retains its own clock and source placeholder.
enum AppleRecordedTranscription {
    static func transcribe(
        files: [URL], meetingID: UUID, language: String,
        progress: (@Sendable (AudioTaskProgress) async -> Void)? = nil,
        status: @escaping @Sendable (String) async -> Void
    ) async throws -> LiveTranscriptDraft {
        let locale = try await AppleLiveTranscription.prepare(language: language) { activity in
            if let message = activity.message { await status(message) }
        }
        try await AppleSpeechAssets.shared.retain(locale)
        do {
            let durations = try AudioTaskProgress.durations(files)
            let total = durations.reduce(0, +)
            var completed = 0.0
            var draft = LiveTranscriptDraft(meetingID: meetingID, locale: locale.identifier)
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let source: LiveAudioSource =
                    file.deletingPathExtension().lastPathComponent.lowercased().contains("mic")
                    ? .microphone : .system
                await status("Transcribing audio \(index + 1) of \(files.count) on This Mac…")
                let started = Date()
                let clockStart = SuspendingClock.now
                let offset = completed
                let duration = durations[index]
                let phase = "Transcribing audio \(index + 1) of \(files.count)"
                await progress?(
                    .init(
                        .init(phase: phase, completed: offset, total: total, unit: "audio seconds", startedAt: started))
                )
                let phrases = try await transcribeFile(file, source: source, locale: locale) { seconds in
                    await progress?(
                        .init(
                            .init(
                                phase: phase, completed: offset + min(duration, max(0, seconds)), total: total,
                                unit: "audio seconds", startedAt: started)))
                }
                try Task.checkCancellation()
                completed += duration
                await progress?(
                    .init(
                        .init(
                            phase: phase, completed: completed, total: total, unit: "audio seconds", startedAt: started),
                        processedAudioSeconds: duration, processingSeconds: AudioTaskProgress.elapsed(since: clockStart)
                    ))
                for phrase in phrases { draft.accept(phrase) }
            }
            draft.complete = true
            await AppleSpeechAssets.shared.releaseUse(locale)
            return draft
        }
        catch {
            await AppleSpeechAssets.shared.releaseUse(locale)
            throw error
        }
    }

    private static func transcribeFile(
        _ file: URL, source: LiveAudioSource, locale: Locale,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> [LiveTranscriptPhrase] {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let session = UUID()
        let pair = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let progressConsumer = Task {
            var frontier = 0.0
            for await seconds in pair.stream {
                guard !Task.isCancelled else { break }
                guard seconds.isFinite, seconds > frontier else { continue }
                frontier = seconds
                await progress(seconds)
            }
        }
        await analyzer.setVolatileRangeChangedHandler { range, changedStart, _ in
            // The end marks submitted audio; only the start marks finalized analysis.
            if changedStart { pair.continuation.yield(range.start.seconds) }
        }
        return try await withTaskCancellationHandler {
            let results = Task { try await collect(transcriber, session: session, source: source, locale: locale) }
            do {
                let end: CMTime?
                if ["opus", "ogg"].contains(file.pathExtension.lowercased()) {
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                    else { throw ServiceError("This Mac couldn’t select an audio format for transcription.") }
                    let input = try RecordedOpusInput(file: file, format: format)
                    let sequence = AsyncThrowingStream<AnalyzerInput, Error>(unfolding: { try await input.next() })
                    end = try await analyzer.analyzeSequence(sequence)
                }
                else {
                    let audio = try AVAudioFile(forReading: file)
                    end = try await analyzer.analyzeSequence(from: audio)
                }
                if let end {
                    try await analyzer.finalizeAndFinish(through: end)
                }
                else {
                    await analyzer.cancelAndFinishNow()
                }
                let phrases = try await results.value
                pair.continuation.finish()
                await progressConsumer.value
                return phrases
            }
            catch {
                results.cancel()
                pair.continuation.finish()
                progressConsumer.cancel()
                await progressConsumer.value
                await analyzer.cancelAndFinishNow()
                _ = try? await results.value
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func collect(
        _ transcriber: SpeechTranscriber, session: UUID, source: LiveAudioSource, locale: Locale
    ) async throws -> [LiveTranscriptPhrase] {
        var phrases: [LiveTranscriptPhrase] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            guard result.isFinal else { continue }
            let timing = AppleTranscriptTiming.extract(result.text)
            phrases.append(
                LiveTranscriptPhrase(
                    session: session, source: source,
                    start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds,
                    text: timing.text, words: timing.words, textTiming: timing.timing, locale: locale.identifier))
        }
        return phrases
    }
}

/// SpeechAnalyzer pulls each buffer on demand. There is no producer queue or PCM spool.
/// One converter spans the recording and receives endOfStream to drain its final samples.
actor RecordedOpusInput {
    private let reader: OpusFileDecoder
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let format: AVAudioFormat
    private var outputFrames: Int64 = 0
    private var finished = false

    init(file: URL, format: AVAudioFormat) throws {
        reader = try OpusFileDecoder(file)
        guard reader.totalFrames > 0,
            let converter = AVAudioConverter(from: StreamingAudioReader.format, to: format),
            let input = AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 8192)
        else { throw ServiceError("Couldn’t prepare transcription audio.") }
        self.converter = converter
        converter.primeMethod = .normal
        self.input = input
        self.format = format
    }

    func next() throws -> AnalyzerInput? {
        guard let item = try nextBuffer() else { return nil }
        return AnalyzerInput(buffer: item.buffer, bufferStartTime: item.start)
    }

    func nextBuffer() throws -> (buffer: AVAudioPCMBuffer, start: CMTime)? {
        try Task.checkCancellation()
        guard !finished else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw ServiceError("Couldn’t prepare transcription audio.")
        }
        var conversionError: NSError?
        var readError: Error?
        let state = converter.convert(to: output, error: &conversionError) { [self] requested, status in
            do {
                try Task.checkCancellation()
                try reader.read(into: input, frames: min(requested, input.frameCapacity))
                status.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                return input.frameLength == 0 ? nil : input
            }
            catch {
                readError = error
                status.pointee = .endOfStream
                return nil
            }
        }
        if let readError { throw readError }
        if state == .error { throw conversionError ?? ServiceError("Couldn’t decode audio for transcription.") }
        finished = state == .endOfStream
        guard output.frameLength > 0 else {
            guard finished else { throw ServiceError("The audio decoder stopped before transcription was complete.") }
            return nil
        }
        let start = CMTime(value: outputFrames, timescale: Int32(format.sampleRate))
        outputFrames += Int64(output.frameLength)
        return (output, start)
    }
}
