import AVFoundation
import CoreMedia
import OSLog
import Speech

/// Public SpeechAnalyzer APIs are macOS 26+. No legacy recognizer or cloud fallback is used.
@available(macOS 26.0, *)
actor AppleLiveTranscription {
    struct Session {
        let analyzer: SpeechAnalyzer
        let queue: LiveAudioQueue
        let feed: Task<Void, Never>
        let results: Task<Void, Never>
        let source: LiveAudioSource
        let gap: @Sendable (LiveTranscriptGap) async -> Void
    }
    private var sessions: [Session] = []
    private var cancelled = false
    private var retainedLocale: Locale?
    private var failed = false
    private func markFailed() { failed = true }
    static let log = Logger(subsystem: "com.gdaymeetings.macos", category: "live-transcription")

    static func locale(for language: String) async -> Locale? {
        AppleSpeechLanguageMapping.locale(for: language, supported: await SpeechTranscriber.supportedLocales)
    }

    static func prepare(language: String, status: @Sendable (String) async -> Void) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw MeetingError.message("Live transcript isn’t available on this Mac.")
        }
        guard let locale = await locale(for: language) else {
            throw MeetingError.message("Live transcript isn’t available for this language on this Mac.")
        }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let readiness = await AssetInventory.status(forModules: [module])
        guard readiness != .unsupported else {
            throw MeetingError.message("Live transcript isn’t available for this language on this Mac.")
        }
        try await AppleSpeechAssets.shared.reserve(locale)
        if readiness != .installed {
            await status(
                "Preparing the \(locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? language) speech model…"
            )
            log.notice("Speech model installation requested: locale \(locale.identifier, privacy: .public)")
            do {
                try await AppleSpeechAssets.shared.reserve(locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
                log.notice("Speech model installation completed: locale \(locale.identifier, privacy: .public)")
            }
            catch {
                log.error("Speech model installation failed: locale \(locale.identifier, privacy: .public)")
                throw MeetingError.message(
                    "Couldn’t download the speech model. Check your internet connection and available storage, then turn Live Transcript on again."
                )
            }
        }
        try Task.checkCancellation()
        return locale
    }

    func start(
        locale: Locale, sources: [LiveAudioSource], sink: LiveAudioSink,
        boundaries: [LiveAudioSource: Double] = [:],
        receive: @escaping @Sendable (LiveTranscriptPhrase, Bool) async -> Void,
        gap: @escaping @Sendable (LiveTranscriptGap) async -> Void,
        failure: @escaping @Sendable (String) async -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        try await AppleSpeechAssets.shared.retain(locale)
        retainedLocale = locale
        var queues: [LiveAudioSource: LiveAudioQueue] = [:]
        for source in sources {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw MeetingError.message("This Mac couldn’t prepare live transcription audio.")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
            guard !cancelled else {
                await analyzer.cancelAndFinishNow()
                throw CancellationError()
            }
            let input = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(8))
            try await analyzer.start(inputSequence: input.stream)
            let queue = LiveAudioQueue()
            let sessionID = UUID()
            let results = Task {
                do {
                    for try await result in transcriber.results {
                        let range = result.range
                        let words = result.text.runs.compactMap { run -> LiveTranscriptWord? in
                            guard let time = run.audioTimeRange else { return nil }
                            return LiveTranscriptWord(
                                text: String(result.text[run.range].characters),
                                start: time.start.seconds, end: CMTimeRangeGetEnd(time).seconds)
                        }
                        await receive(
                            LiveTranscriptPhrase(
                                session: sessionID, source: source,
                                start: range.start.seconds, end: CMTimeRangeGetEnd(range).seconds,
                                text: String(result.text.characters), words: words, locale: locale.identifier),
                            result.isFinal)
                    }
                }
                catch {
                    if !Task.isCancelled {
                        self.markFailed()
                        let issue = error as NSError
                        Self.log.error(
                            "Recognition failed: domain \(issue.domain, privacy: .public), code \(issue.code)")
                        if ProcessInfo.processInfo.environment["GDAY_APPLE_LIVE_TEST"] == "1" {
                            print("Speech smoke failure: \(issue.domain) \(issue.code) \(issue.localizedDescription)")
                        }
                        await failure("Live transcript stopped for \(source.title). Recording continues.")
                    }
                }
            }
            let feed = Task {
                let converter = LivePCMConverter(output: format)
                var previousEnd = boundaries[source] ?? 0
                var outputFrame: Int64?
                for await packet in queue.stream {
                    queue.consumed(packet)
                    if Task.isCancelled { break }
                    do {
                        if packet.start - previousEnd >= 0.1 {
                            await gap(
                                .init(
                                    source: source, start: previousEnd, end: packet.start,
                                    reason: "Audio was not processed for live transcription."))
                            converter.reset()
                            outputFrame = nil
                        }
                        if let buffer = try converter.convert(packet.buffer) {
                            // Resampling can hold or release samples across callback boundaries.
                            // Timestamp converted frames on one cursor, not each source packet's start.
                            let start = outputFrame ?? Int64((packet.start * format.sampleRate).rounded())
                            let value = AnalyzerInput(
                                buffer: buffer,
                                bufferStartTime: CMTime(value: start, timescale: Int32(format.sampleRate)))
                            outputFrame = start + Int64(buffer.frameLength)
                            switch input.continuation.yield(value) {
                            case .dropped:
                                await gap(
                                    .init(
                                        source: source, start: packet.start, end: packet.start + packet.duration,
                                        reason: "Live transcription couldn’t keep up."))
                            default: break
                            }
                        }
                        previousEnd = packet.start + packet.duration
                    }
                    catch {
                        self.markFailed()
                        await failure("Live transcript stopped for \(source.title). Recording continues.")
                        break
                    }
                }
                input.continuation.finish()
            }
            sessions.append(
                Session(analyzer: analyzer, queue: queue, feed: feed, results: results, source: source, gap: gap))
            queues[source] = queue
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        sink.replace(queues)
    }

    func finish() async -> Bool {
        let pending = sessions
        guard !pending.isEmpty, !cancelled else { return false }
        for session in pending { session.queue.finish() }
        for session in pending {
            await session.feed.value
            do { try await session.analyzer.finalizeAndFinishThroughEndOfInput() }
            catch {
                failed = true
                await session.analyzer.cancelAndFinishNow()
            }
            await session.results.value
            for range in session.queue.takeDroppedRanges() {
                await session.gap(
                    .init(
                        source: session.source, start: range.0, end: range.1,
                        reason: "Live transcription couldn’t keep up."))
            }
        }
        sessions.removeAll()
        await releaseLocale()
        return !failed
    }

    func cancel() async {
        cancelled = true
        let pending = sessions
        sessions.removeAll()
        for session in pending {
            session.queue.finish()
            session.feed.cancel()
            session.results.cancel()
            await session.analyzer.cancelAndFinishNow()
        }
        await releaseLocale()
    }
    private func releaseLocale() async {
        guard let locale = retainedLocale else { return }
        retainedLocale = nil
        await AppleSpeechAssets.shared.releaseUse(locale)
    }
}

/// AssetInventory reservations belong to this app and survive launches. Never evict a locale in use.
@available(macOS 26.0, *)
actor AppleSpeechAssets {
    static let shared = AppleSpeechAssets()
    private var active: [String: Int] = [:]
    func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(locale) { return }
        if reserved.count >= AssetInventory.maximumReservedLocales {
            guard let old = reserved.first(where: { (active[$0.identifier] ?? 0) == 0 }) else {
                throw MeetingError.message(
                    "Finish the current live transcript before downloading another speech model.")
            }
            _ = await AssetInventory.release(reservedLocale: old)
        }
        _ = try await AssetInventory.reserve(locale: locale)
    }
    func retain(_ locale: Locale) async throws {
        try await reserve(locale)
        active[locale.identifier, default: 0] += 1
    }
    func releaseUse(_ locale: Locale) {
        active[locale.identifier] = max(0, (active[locale.identifier] ?? 0) - 1)
    }
}

/// Persistent rate conversion runs on the provider task, away from capture. Input format changes reset history.
final class LivePCMConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?
    init(output: AVAudioFormat) { self.output = output }
    func reset() { converter?.reset() }
    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if input.format == output { return input }
        if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: output) }
        guard let converter,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: output,
                frameCapacity: AVAudioFrameCount(
                    ceil(Double(input.frameLength) * output.sampleRate / input.format.sampleRate)) + 64)
        else { throw MeetingError.message("Couldn’t convert live transcription audio.") }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: buffer, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if result == .error { throw error ?? NSError(domain: "LiveTranscript", code: 1) }
        return buffer.frameLength > 0 ? buffer : nil
    }
}
