import AVFoundation
import CoreMedia
import OSLog
import Speech

/// Uses SpeechAnalyzer on supported hardware and languages, with no cloud fallback.
actor AppleLiveTranscription {
    struct Session {
        let analyzer: SpeechAnalyzer
        let queue: LiveAudioQueue
        let reporter: LiveTranscriptGapReporter
        let results: Task<Void, Never>
        let source: LiveAudioSource
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
            throw MeetingError.message("Transcription isn’t available on this Mac.")
        }
        guard let locale = await locale(for: language) else {
            throw MeetingError.message("Transcription isn’t available for this language on this Mac.")
        }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let readiness = await AssetInventory.status(forModules: [module])
        guard readiness != .unsupported else {
            throw MeetingError.message("Transcription isn’t available for this language on this Mac.")
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
                    "Couldn’t download the speech model. Check your internet connection and available storage, then try transcription again."
                )
            }
        }
        try Task.checkCancellation()
        return locale
    }

    @discardableResult func start(
        locale: Locale, sources: [LiveAudioSource], sink: LiveAudioSink,
        boundaries: [LiveAudioSource: Double] = [:],
        receive: @escaping @Sendable (LiveTranscriptPhrase, Bool) async -> Void,
        gap: @escaping @Sendable (LiveTranscriptGap) async -> Void,
        failure: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderResult<Void> {
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
            let queue = LiveAudioQueue()
            let reporter = LiveTranscriptGapReporter(deliver: gap)
            let input = AppleLiveAudioInput(
                queue: queue, format: format, boundary: boundaries[source] ?? 0, source: source,
                reporter: reporter,
                failure: { message in
                    await self.markFailed()
                    await failure(message)
                })
            // The analyzer pulls converted packets. The duration-bounded capture
            // queue is the sole backlog; tiny system packets have the same budget as microphone packets.
            try await analyzer.start(inputSequence: AsyncStream(unfolding: { await input.next() }))
            let sessionID = UUID()
            let results = Task(name: "Live transcription results: \(source.rawValue)") {
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
            sessions.append(
                Session(
                    analyzer: analyzer, queue: queue, reporter: reporter, results: results, source: source))
            queues[source] = queue
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        sink.replace(queues)
        return ProviderResult(
            value: (),
            dataFlow: DataFlow(
                location: .local, targetID: ThisMacProvider.id, targetName: "This Mac", startedAt: Date(),
                bodies: sources.map(\.title), purpose: "Live transcription"))
    }

    func finish() async -> Bool {
        let pending = sessions
        guard !pending.isEmpty, !cancelled else { return false }
        for session in pending { session.queue.finish() }
        for session in pending {
            do { try await session.analyzer.finalizeAndFinishThroughEndOfInput() }
            catch {
                failed = true
                await session.analyzer.cancelAndFinishNow()
            }
            await session.results.value
            for range in session.queue.takeDroppedRanges() {
                session.reporter.append(
                    .init(
                        source: session.source, start: range.start, end: range.end,
                        reason: range.isExact
                            ? "Live transcription couldn’t keep up."
                            : "Some audio within this interval could not be transcribed; exact gaps are unavailable."))
            }
            await session.reporter.flush()
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
            session.results.cancel()
            await session.analyzer.cancelAndFinishNow()
            await session.reporter.flush()
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
actor AppleSpeechAssets {
    static let shared = AppleSpeechAssets()
    private var active: [String: Int] = [:]
    func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(locale) { return }
        if reserved.count >= AssetInventory.maximumReservedLocales {
            guard let old = reserved.first(where: { (active[$0.identifier] ?? 0) == 0 }) else {
                throw MeetingError.message(
                    "Wait for transcription to finish before downloading another speech model.")
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

/// SpeechAnalyzer requests one converted packet at a time. Device changes keep
/// the same queue and recording clock; only conversion history resets at a gap.
actor AppleLiveAudioInput {
    private var iterator: AsyncStream<LiveAudioQueue.Packet>.Iterator
    private let queue: LiveAudioQueue
    private let converter: LivePCMConverter
    private var timeline: LiveAudioInputTimeline
    private let format: AVAudioFormat
    private let source: LiveAudioSource
    private let reporter: LiveTranscriptGapReporter
    private let failure: @Sendable (String) async -> Void
    private var ended = false

    init(
        queue: LiveAudioQueue, format: AVAudioFormat, boundary: Double, source: LiveAudioSource,
        reporter: LiveTranscriptGapReporter, failure: @escaping @Sendable (String) async -> Void
    ) {
        self.queue = queue
        iterator = queue.stream.makeAsyncIterator()
        converter = LivePCMConverter(output: format)
        timeline = LiveAudioInputTimeline(boundary: boundary)
        self.format = format
        self.source = source
        self.reporter = reporter
        self.failure = failure
    }

    func next() async -> AnalyzerInput? {
        guard !ended else { return nil }
        while !Task.isCancelled {
            // AsyncStream calls its unfolding closure serially; no concurrent next calls.
            var current = iterator
            guard let packet = await current.next() else {
                ended = true
                return nil
            }
            iterator = current
            queue.consumed(packet)
            do {
                let previousEnd = timeline.previousEnd
                if timeline.receive(start: packet.start, duration: packet.duration) {
                    reporter.append(
                        .init(
                            source: source, start: previousEnd, end: packet.start,
                            reason: "Audio was not processed for live transcription."))
                    converter.reset()
                }
                guard let buffer = try converter.convert(packet.buffer) else { continue }
                guard
                    let start = timeline.convertedStart(
                        frameCount: Int(buffer.frameLength), sampleRate: format.sampleRate)
                else { throw MeetingError.message("Couldn’t align live transcription audio.") }
                return AnalyzerInput(
                    buffer: buffer, bufferStartTime: CMTime(value: start, timescale: Int32(format.sampleRate)))
            }
            catch {
                ended = true
                queue.finish()
                await failure("Live transcript stopped for \(source.title). Recording continues.")
                return nil
            }
        }
        ended = true
        return nil
    }
}
