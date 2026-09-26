import Combine
import Foundation

/// Partial results publish only to the live panel, never through the meeting library.
@MainActor
final class LiveTranscriptController: ObservableObject {
    @Published private(set) var draft: LiveTranscriptDraft?
    @Published private(set) var partials: [LiveTranscriptPhrase] = []
    @Published private(set) var status = ""
    @Published private(set) var enabled = false
    private var generation = UUID()
    private var acceptedGenerations = Set<UUID>()
    private var directory: URL?
    private var sources: [LiveAudioSource] = []
    private var boundaries: [LiveAudioSource: Double] = [:]
    private var sink: LiveAudioSink?
    private var startup: Task<Void, Never>?
    private var stopProvider: (() async -> Bool)?
    private var pendingFinalizations: [UUID: Task<Bool, Never>] = [:]
    private var finalizationFailed = false
    private var ready = false
    private var cancelProvider: (() async -> Void)?

    func begin(
        meetingID: UUID, language: String, directory: URL, sources: [LiveAudioSource],
        sink: LiveAudioSink, enabled: Bool
    ) {
        acceptedGenerations = []
        pendingFinalizations = [:]
        finalizationFailed = false
        boundaries = [:]
        self.enabled = false
        self.directory = directory
        self.sources = sources
        self.sink = sink
        draft = LiveTranscriptDraft(meetingID: meetingID, locale: language)
        setEnabled(enabled)
    }

    func seedPreview(meetingID: UUID, directory: URL) {
        begin(
            meetingID: meetingID, language: "en", directory: directory,
            sources: [.microphone, .system], sink: LiveAudioSink(), enabled: true)
        draft?.accept(
            .init(
                session: UUID(), source: .system, start: 1, end: 4,
                text: "Let’s review the release plan.", locale: "en-AU"))
        partials = [
            .init(
                session: UUID(), source: .microphone, start: 5, end: 8,
                text: "I’ll update the schedule…", locale: "en-AU")
        ]
        checkpoint()
    }

    func changeLanguage(_ language: String) {
        guard draft?.locale != language else { return }
        draft?.locale = language
        if enabled { setEnabled(true) }
    }

    func setEnabled(_ value: Bool) {
        // On restart, only the interval since recognition was detached is uncovered.
        // On first start the boundary is zero, including model preparation time.
        if enabled {
            if !ready { recordInactiveCoverage() }
            boundaries = sink?.positions() ?? [:]
        }
        let previous = generation
        if let stopProvider {
            finalizeDetachedSession(token: previous, work: stopProvider, cancel: cancelProvider)
        }
        ready = false
        generation = UUID()
        let token = generation
        acceptedGenerations.insert(token)
        startup?.cancel()
        sink?.replace([:])
        stopProvider = nil
        cancelProvider = nil
        partials = []
        enabled = value
        guard value, let draft, let sink else {
            status = "Live transcript is off."
            return
        }
        if UIPreview.enabled {
            status = "Synthetic live transcript · No recognition is running."
            return
        }
        status = "Preparing live transcript…"
        checkpoint()
        guard #available(macOS 26.0, *) else {
            status = "Live transcript requires macOS 26 or later."
            return
        }
        let provider = AppleLiveTranscription()
        let boundaries = self.boundaries
        cancelProvider = { await provider.cancel() }
        stopProvider = { await provider.finish() }
        startup = Task { [self] in
            do {
                let locale = try await AppleLiveTranscription.prepare(language: draft.locale) { [weak self] value in
                    await self?.setStatus(value, token: token)
                }
                guard generation == token, !Task.isCancelled else { return }
                self.draft?.locale = locale.identifier
                try await provider.start(
                    locale: locale, sources: sources, sink: sink, boundaries: boundaries,
                    receive: { [weak self] phrase, final in await self?.receive(phrase, final: final, token: token) },
                    gap: { [weak self] gap in await self?.recordGap(gap, token: token) },
                    failure: { [weak self] message in await self?.setStatus(message, token: token) })
                guard generation == token else {
                    await provider.cancel()
                    return
                }
                ready = true
                status = "Listening · This Mac"
            }
            catch {
                await provider.cancel()
                guard generation == token, !Task.isCancelled else { return }
                status = error.localizedDescription
                checkpoint()
            }
        }
    }

    /// Keep a detached session eligible to deliver its last result until its deadline.
    func finalizeDetachedSession(
        token: UUID, work: @escaping () async -> Bool, cancel: (() async -> Void)?
    ) {
        acceptedGenerations.insert(token)
        pendingFinalizations[token] = Task {
            let finished = await LiveFinishRace.run(seconds: 5, work: work)
            if !finished, let cancel { Task { await cancel() } }
            acceptedGenerations.remove(token)
            if !finished { finalizationFailed = true }
            pendingFinalizations.removeValue(forKey: token)
            return finished
        }
    }

    func finish() async {
        if !enabled || !ready { recordInactiveCoverage() }
        sink?.replace([:])
        startup?.cancel()
        if let stopProvider {
            status = "Finishing live transcript…"
            let finished = await LiveFinishRace.run(seconds: 5, work: stopProvider)
            if !finished, let cancelProvider { Task { await cancelProvider() } }
            draft?.complete = finished && ready && (draft?.gaps.isEmpty ?? true)
            status = finished ? "Live draft saved." : "Live draft saved. The last phrase may be incomplete."
        }
        else {
            draft?.complete = false
        }
        // Detached sessions are already finalizing concurrently. Preserve their last
        // finalized phrases before closing the draft, including rapid toggle/Stop.
        for task in Array(pendingFinalizations.values) {
            if !(await task.value) { finalizationFailed = true }
        }
        if !(draft?.gaps.isEmpty ?? true) { draft?.complete = false }
        if finalizationFailed {
            draft?.complete = false
            status = "Live draft saved. The last phrase may be incomplete."
        }
        acceptedGenerations = []
        generation = UUID()
        partials = []
        checkpoint()
        stopProvider = nil
        cancelProvider = nil
        sink = nil
    }

    private func recordInactiveCoverage() {
        let positions = sink?.positions() ?? [:]
        for source in sources {
            let start = boundaries[source] ?? 0
            let end = positions[source] ?? start
            if end > start {
                draft?.gaps.append(
                    .init(
                        source: source, start: start, end: end,
                        reason: "Live transcription was not running."))
            }
        }
    }

    private func setStatus(_ value: String, token: UUID) {
        guard token == generation else { return }
        status = value
    }
    private func recordGap(_ value: LiveTranscriptGap, token: UUID) {
        guard acceptedGenerations.contains(token) else { return }
        draft?.gaps.append(value)
        checkpoint()
    }
    func receive(_ value: LiveTranscriptPhrase, final: Bool, token: UUID) {
        guard acceptedGenerations.contains(token) else { return }
        partials.removeAll { $0.source == value.source && $0.session == value.session }
        if final {
            draft?.accept(value)
            checkpoint()
        }
        else if token == generation {
            partials.append(value)
        }
    }
    private func checkpoint() {
        guard let draft, let directory else { return }
        do { try draft.save(at: directory) }
        catch { status = "Couldn’t save the live draft. Recording continues. Check available storage." }
    }
}

/// Unstructured race bounds UI stop even if a framework ignores cooperative cancellation.
private final class LiveFinishRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resolve(_ value: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
    static func run(seconds: Double, work: @escaping () async -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = LiveFinishRace(continuation)
            Task {
                race.resolve(await work())
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                race.resolve(false)
            }
        }
    }
}
