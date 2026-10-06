import AVFoundation
import CoreMedia
import Speech

/// File input is pulled by SpeechAnalyzer without the bounded live-capture queue.
/// Each recording track retains its own clock and source placeholder.
enum AppleRecordedTranscription {
    static func transcribe(
        files: [URL], meetingID: UUID, language: String,
        status: @escaping @Sendable (String) async -> Void
    ) async throws -> LiveTranscriptDraft {
        let locale = try await AppleLiveTranscription.prepare(language: language, status: status)
        try await AppleSpeechAssets.shared.retain(locale)
        do {
            var draft = LiveTranscriptDraft(meetingID: meetingID, locale: locale.identifier)
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                await status("Transcribing audio \(index + 1) of \(files.count) on This Mac…")
                let source: LiveAudioSource =
                    file.deletingPathExtension().lastPathComponent.lowercased().contains("mic")
                    ? .microphone : .system
                let prepared = try prepareInput(file)
                defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }
                let phrases = try await transcribeFile(prepared.url, source: source, locale: locale)
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

    /// Use the same libopusfile decoder as playback, including end trimming.
    private static func prepareInput(_ file: URL) throws -> PreparedPlaybackAudio {
        guard ["opus", "ogg"].contains(file.pathExtension.lowercased()) else {
            return .init(url: file, temporary: false)
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gday-transcription-\(UUID()).caf")
        do {
            let reader = try OpusFileDecoder(file)
            let format = StreamingAudioReader.format
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw ServiceError("Couldn’t prepare transcription audio.")
            }
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let output = try AVAudioFile(forWriting: destination, settings: settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            while true {
                try Task.checkCancellation()
                try reader.read(into: buffer, frames: buffer.frameCapacity)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            return .init(url: destination, temporary: true)
        }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func transcribeFile(
        _ file: URL, source: LiveAudioSource, locale: Locale
    ) async throws -> [LiveTranscriptPhrase] {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let session = UUID()
        return try await withTaskCancellationHandler {
            let results = Task { try await collect(transcriber, session: session, source: source, locale: locale) }
            do {
                let audio = try AVAudioFile(forReading: file)
                if let end = try await analyzer.analyzeSequence(from: audio) {
                    try await analyzer.finalizeAndFinish(through: end)
                }
                else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await results.value
            }
            catch {
                results.cancel()
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
            let words = result.text.runs.compactMap { run -> LiveTranscriptWord? in
                guard let time = run.audioTimeRange else { return nil }
                return LiveTranscriptWord(
                    text: String(result.text[run.range].characters),
                    start: time.start.seconds, end: CMTimeRangeGetEnd(time).seconds)
            }
            phrases.append(
                LiveTranscriptPhrase(
                    session: session, source: source,
                    start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds,
                    text: String(result.text.characters), words: words, locale: locale.identifier))
        }
        return phrases
    }
}
