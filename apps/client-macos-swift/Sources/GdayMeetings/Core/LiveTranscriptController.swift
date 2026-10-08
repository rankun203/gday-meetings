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
    private var dataEvents: [UUID: MeetingDataEvent] = [:]
    private var cancelProvider: (() async -> Void)?
    private var knownRecognitionSessions = Set<UUID>()
    @Published private var transcriptionIssue: String?
    @Published private var transcriptionFailures: [String] = []
    @Published private var checkpointIssue: String?
    @Published private var dataEventIssue: String?
    private var projectionWriter = LiveTranscriptProjectionWriter()
    @Published private var projectionIssue: String?
    private var checkpointGeneration = UUID()
    private let resolutionCache = LiveTranscriptResolutionCache()
    let stream = LiveTranscriptStream()
    @Published private(set) var streamRevision = 0
    var presentedStream: LiveTranscriptStream { stream }

    private func publishStream() {
        streamRevision = stream.revision
        if let draft { saveProjection(draft) }
    }

    private let speakerDisplayCache = LiveTranscriptSpeakerDisplayCache()

    var liveTranscriptIssues: [String] {
        let issues =
            [transcriptionIssue, checkpointIssue, projectionIssue, dataEventIssue].compactMap {
                $0
            }
            + transcriptionFailures
        var seen = Set<String>()
        return issues.filter { seen.insert($0).inserted }
    }
    private var peopleProvider: () -> [Person] = { [] }

    var presentedRows: (finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase]) {
        let people = Set(peopleProvider().map(\.id))
        var presentation = draft
        presentation?.effectivePhrases = stream.snapshot.phrases
        let resolved =
            presentation?.resolvedRows(partials: stream.hotPartials, cache: resolutionCache)
            ?? (finalized: [], partials: partials)
        return (
            finalized: speakerDisplayCache.rows(
                resolved.finalized, meetingID: draft?.meetingID, enabled: false, people: people),
            partials: resolved.partials.map { $0.displayingSpeakerLabels(false, knownPeople: people) }
        )
    }
    var presentedFinalized: [LiveTranscriptPhrase] { presentedRows.finalized }
    var presentedPartials: [LiveTranscriptPhrase] { presentedRows.partials }

    func updateText(rowID: UUID, text: String) {
        let rows = presentedRows
        guard let phrase = (rows.finalized + rows.partials).first(where: { $0.id == rowID }) else { return }
        updateText(phrase: phrase, text: text)
    }

    /// The editor captures this anchor when editing begins, before recognition
    /// can merge, split, or replace the row currently visible in the table.
    func updateText(phrase: LiveTranscriptPhrase, text: String) {
        guard knownRecognitionSessions.contains(phrase.session) else { return }
        draft?.updateText(text, for: phrase)
        refreshEdits()
        checkpoint()
    }

    private func refreshEdits() {
        stream.updateEdits(draft?.overrides ?? [], speakers: draft?.speakerTimeline?.speakers ?? [])
        publishStream()
    }

    /// Recording has one analysis consumer: live transcription. Speaker identity
    /// is produced from the completed recording by the offline diarization job.
    func begin(
        meetingID: UUID, language: String, directory: URL, sources: [LiveAudioSource],
        sink: LiveAudioSink, enabled: Bool, people: @escaping () -> [Person] = { [] }
    ) {
        transcriptionIssue = nil
        transcriptionFailures = []
        checkpointIssue = nil
        dataEventIssue = nil
        projectionWriter = LiveTranscriptProjectionWriter()
        projectionIssue = nil
        checkpointGeneration = UUID()
        stream.reset(labeling: false, sources: sources)
        acceptedGenerations = []
        knownRecognitionSessions = []
        peopleProvider = people
        pendingFinalizations = [:]
        finalizationFailed = false
        boundaries = [:]
        self.enabled = false
        self.directory = directory
        self.sources = sources
        self.sink = sink
        draft = LiveTranscriptDraft(meetingID: meetingID, locale: language)
        draft?.liveSources = sources
        publishStream()
        setEnabled(enabled)
    }

    func seedPreview(meetingID: UUID, directory: URL, previouslyAssignedPersonID: UUID? = nil) {
        begin(
            meetingID: meetingID, language: "en", directory: directory,
            sources: [.microphone, .system], sink: LiveAudioSink(), enabled: true)
        let microphoneSession = UUID()
        let systemSession = UUID()
        knownRecognitionSessions.formUnion([microphoneSession, systemSession])
        for index in 0..<18 {
            let source: LiveAudioSource = index.isMultiple(of: 2) ? .system : .microphone
            let phrase = LiveTranscriptPhrase(
                session: source == .system ? systemSession : microphoneSession,
                source: source, start: Double(index * 5 + 1), end: Double(index * 5 + 4),
                text: index == 8
                    ? "The draft includes the schedule, open questions, and the next review. We can check each section together and record any changes before sharing it."
                    : (index.isMultiple(of: 2) ? "Let’s review the next item." : "I’ll add that to the draft."),
                locale: "en-AU", personID: index == 0 ? previouslyAssignedPersonID : nil)
            draft?.accept(phrase)
            stream.accept(phrase, final: true)
        }
        partials = [
            .init(
                session: systemSession, source: .system, start: 91, end: 94,
                text: "The next review will cover…", locale: "en-AU", recognizedFinal: false),
            .init(
                session: microphoneSession, source: .microphone, start: 94, end: 97,
                text: "I’ll update the schedule…", locale: "en-AU", recognizedFinal: false),
        ]
        for phrase in partials {
            stream.accept(phrase, final: false)
        }
        publishStream()
        checkpoint()
    }

    func changeLanguage(_ language: String) {
        guard draft?.locale != language else { return }
        draft?.locale = language
        if enabled { setEnabled(true) }
    }

    func setEnabled(_ value: Bool) {
        transcriptionIssue = nil
        transcriptionFailures = []
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
        stream.discardPartials()
        publishStream()
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
        let provider = AppleLiveTranscription()
        let boundaries = self.boundaries
        cancelProvider = { await provider.cancel() }
        stopProvider = { await provider.finish() }
        startup = Task(name: "Start live transcription") { [self] in
            do {
                let locale = try await AppleLiveTranscription.prepare(language: draft.locale) { [weak self] value in
                    await self?.setStatus(value, token: token)
                }
                guard generation == token, !Task.isCancelled else { return }
                self.draft?.locale = locale.identifier
                let result = try await provider.start(
                    locale: locale, sources: sources, sink: sink, boundaries: boundaries,
                    receive: { [weak self] phrase, final in await self?.receive(phrase, final: final, token: token) },
                    gap: { [weak self] gap in await self?.recordGap(gap, token: token) },
                    failure: { [weak self] message in await self?.receiveTranscriptionFailure(message, token: token) })
                guard generation == token else {
                    await provider.cancel()
                    return
                }
                ready = true
                status = "Listening · This Mac"
                let event = MeetingDataEvent(action: .sent, dataFlow: result.dataFlow)
                dataEvents[token] = event
                if let directory {
                    do {
                        try DataEventJournal.append(event, directory: directory)
                        dataEventIssue = nil
                    }
                    catch {
                        dataEventIssue = "Couldn’t save the live processing data event."
                    }
                }
            }
            catch {
                await provider.cancel()
                guard generation == token, !Task.isCancelled else { return }
                status = error.localizedDescription
                transcriptionIssue = status
                checkpoint()
            }
        }
    }

    /// Keep a detached session eligible to deliver its last result until its deadline.
    func finalizeDetachedSession(
        token: UUID, work: @escaping () async -> Bool, cancel: (() async -> Void)?
    ) {
        acceptedGenerations.insert(token)
        pendingFinalizations[token] = Task(name: "Finish live transcription") {
            let finished = await LiveFinishRace.run(seconds: 5, work: work)
            if !finished, let cancel { Task { await cancel() } }
            acceptedGenerations.remove(token)
            if !finished { finalizationFailed = true }
            closeDataEvent(token)
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
        closeDataEvent(generation)
        generation = UUID()
        partials = []
        stream.finish()
        publishStream()
        checkpoint()
        await flushCheckpoint()
        if var draft {
            if checkpointIssue != nil {
                draft.complete = false
                draft.speakerLabelsComplete = false
            }
            saveProjection(draft, finished: true)
        }
        await projectionWriter.flush()
        await materializeFinishedDraft()
        stopProvider = nil
        cancelProvider = nil
        sink = nil
    }

    private func recordInactiveCoverage() {
        let positions = sink?.positions() ?? [:]
        var gaps: [LiveTranscriptGap] = []
        for source in sources {
            let start = boundaries[source] ?? 0
            let end = positions[source] ?? start
            if end > start {
                let gap = LiveTranscriptGap(
                    source: source, start: start, end: end,
                    reason: "Live transcription was not running.")
                gaps.append(gap)
            }
        }
        guard !gaps.isEmpty else { return }
        draft?.gaps.append(contentsOf: gaps)
        stream.accept(gaps)
        publishStream()
    }

    func receiveTranscriptionFailure(_ message: String, token: UUID) {
        guard acceptedGenerations.contains(token) else { return }
        status = message
        if !transcriptionFailures.contains(message) { transcriptionFailures.append(message) }
    }

    private func setStatus(_ value: String, token: UUID) {
        guard token == generation else { return }
        status = value
    }
    private func recordGap(_ value: LiveTranscriptGap, token: UUID) {
        guard acceptedGenerations.contains(token) else { return }
        draft?.gaps.append(value)
        stream.accept(value)
        publishStream()
        checkpoint()
    }
    func receive(_ value: LiveTranscriptPhrase, final: Bool, token: UUID) {
        guard acceptedGenerations.contains(token), value.isAdmissible else { return }
        knownRecognitionSessions.insert(value.session)
        var value = value
        value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.preservingIdentity(from: partials + (draft?.phrases ?? []))
        value.recognizedFinal = final
        guard let prepared = stream.prepare(value) else { return }
        value = prepared
        partials = LiveTranscriptPhrase.replacingPartials(
            partials, with: value, final: final || token != generation)
        stream.accept(value, final: final)
        publishStream()
        if final {
            draft?.phrases.removeAll { $0.end < value.end - LiveTranscriptStream.maximumLabelWait }
            draft?.accept(value)
            checkpoint()
        }
    }
    func receivePreview(_ phrase: LiveTranscriptPhrase, final: Bool) {
        guard UIPreview.enabled else { return }
        receive(phrase, final: final, token: generation)
    }

    private func checkpoint() {
        guard let draft else { return }
        saveProjection(draft)
    }

    private func saveProjection(_ draft: LiveTranscriptDraft, finished: Bool = false) {
        guard let directory else { return }
        let generation = checkpointGeneration
        projectionWriter.submit(draft, snapshot: stream.snapshot, at: directory, finished: finished) {
            [weak self] issue in
            guard let self, self.checkpointGeneration == generation else { return }
            self.projectionIssue = issue
            if let issue { self.status = issue }
        }
    }

    /// Waits for the latest accepted snapshot, including its storage error report.
    func flushCheckpoint() async {
        await projectionWriter.flush()
        checkpointIssue = projectionWriter.issue
    }

    private func materializeFinishedDraft() async {
        guard let directory, let metadata = draft else { return }
        if projectionWriter.issue != nil {
            draft?.effectivePhrases = stream.snapshot.phrases
            draft?.complete = false
            checkpointIssue = projectionWriter.issue
            return
        }
        do {
            // Normal display consumes exactly the saved segments. No raw journal
            // replay, paragraph generation, or second transcript publication.
            draft = try await Task.detached(name: "Read live transcript draft", priority: .utility) {
                try LiveTranscriptDraft.read(at: directory, meetingID: metadata.meetingID)
            }.value
        }
        catch {
            draft?.complete = false
            checkpointIssue = "Couldn’t open the saved transcript. Its checkpoint was kept."
        }
    }
    private func openLocalDataEvent(
        _ token: UUID, targetID: UUID, targetName: String,
        purpose: String, bodies: [String]
    ) {
        guard let directory else { return }
        let event = MeetingDataEvent(
            action: .sent,
            dataFlow: .init(
                location: .local, targetID: targetID, targetName: targetName,
                startedAt: Date(), bodies: bodies, purpose: purpose))
        dataEvents[token] = event
        do {
            try DataEventJournal.append(event, directory: directory)
            dataEventIssue = nil
        }
        catch {
            dataEventIssue = "Couldn’t save the live processing data event."
        }
    }

    private func closeDataEvent(_ token: UUID) {
        guard var event = dataEvents.removeValue(forKey: token), let directory else { return }
        event.dataFlow.endedAt = Date()
        do {
            try DataEventJournal.append(event, directory: directory)
            dataEventIssue = nil
        }
        catch {
            dataEventIssue = "Couldn’t save the live processing data event."
        }
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
