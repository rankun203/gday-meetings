import Combine
import Foundation

/// Partial results publish only to the live panel, never through the meeting library.
@MainActor
final class LiveTranscriptController: ObservableObject {
    @Published private(set) var draft: LiveTranscriptDraft?
    @Published private(set) var partials: [LiveTranscriptPhrase] = []
    @Published private(set) var status = ""
    @Published private(set) var enabled = false
    @Published private(set) var speakerLabelsEnabled = false
    @Published private(set) var speakerLabelStatus = ""
    @Published private(set) var speakerRecognitionEnabled = false
    @Published private(set) var speakerRecognitionStatus = ""
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
    private var diarizationProvider: ServiceProvider?
    private var speakerAnalysisReady = false
    @Published private var transcriptionIssue: String?
    @Published private var transcriptionFailures: [String] = []
    @Published private var checkpointIssue: String?
    @Published private var journalIssue: String?
    @Published private var speakerAnalysisIssue: String?
    @Published private var voiceMatchingIssue: String?
    private var voiceMatchingError: Error?
    private var checkpointWriter = LiveTranscriptCheckpointWriter()
    private var checkpointGeneration = UUID()
    private let resolutionCache = LiveTranscriptResolutionCache()
    private let speakerDisplayCache = LiveTranscriptSpeakerDisplayCache()

    var liveTranscriptIssues: [String] {
        var issues = [transcriptionIssue, checkpointIssue, journalIssue].compactMap { $0 } + transcriptionFailures
        if speakerLabelsEnabled || speakerRecognitionEnabled, let issue = speakerAnalysisIssue { issues.append(issue) }
        if speakerRecognitionEnabled, let issue = voiceMatchingIssue { issues.append(issue) }
        var seen = Set<String>()
        return issues.filter { seen.insert($0).inserted }
    }
    var canOpenProviderSettings: Bool {
        ((speakerLabelsEnabled || speakerRecognitionEnabled) && speakerAnalysisIssue != nil)
            || (speakerRecognitionEnabled && voiceMatchingIssue != nil)
    }

    var speakerStatusMessages: [String] {
        guard speakerLabelsEnabled else { return [] }
        let messages =
            speakerAnalysisReady
            ? [speakerLabelStatus, speakerRecognitionStatus] : [speakerLabelStatus]
        return messages.filter { !$0.isEmpty }
    }
    private var speakerProvider: LocalLiveDiarization?
    private var speakerStartup: Task<Void, Never>?
    private var speakerGeneration = UUID()
    private var acceptedSpeakerGenerations = Set<UUID>()
    private var pendingSpeakerFinalizations: [UUID: Task<Bool, Never>] = [:]
    private var voiceWorker: LiveVoiceEmbeddingWorker?
    private var voiceStartup: Task<Void, Never>?
    private var voiceWork: Task<Void, Never>?
    private var voiceGeneration = UUID()
    private var voiceEmbeddings: [UUID: TypedVoiceEmbedding] = [:]
    private var voiceCandidates: [UUID: (person: UUID, count: Int)] = [:]
    private var peopleProvider: () -> [Person] = { [] }
    private var enrollVoice: ((UUID?, UUID, TypedVoiceEmbedding?) -> Void)?
    private var modelObservation: AnyCancellable?
    private var waitingForSpeakerModel = false
    private var waitingForVoiceModel = false
    private var lastSpeakerCheckpoint = Date.distantPast

    var presentedRows: (finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase]) {
        let people = Set(peopleProvider().map(\.id))
        let resolved =
            draft?.resolvedRows(partials: partials, cache: resolutionCache) ?? (finalized: [], partials: partials)
        return (
            finalized: speakerDisplayCache.rows(
                resolved.finalized, meetingID: draft?.meetingID, enabled: speakerLabelsEnabled, people: people),
            partials: resolved.partials.map { $0.displayingSpeakerLabels(speakerLabelsEnabled, knownPeople: people) }
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
        checkpoint()
    }

    func assignPerson(rowID: UUID, personID: UUID?) {
        let rows = presentedRows
        guard let phrase = (rows.finalized + rows.partials).first(where: { $0.id == rowID }) else { return }
        assignPerson(phrase: phrase, personID: personID)
    }

    func assignPerson(phrase: LiveTranscriptPhrase, personID: UUID?) {
        guard knownRecognitionSessions.contains(phrase.session) else { return }
        draft?.assignPerson(personID, for: phrase, speakerIdentity: phrase.speakerIdentity)
        if let identity = phrase.speakerIdentity {
            draft?.speakerTimeline?.assign(personID, to: identity, manual: true)
            enrollVoice?(personID, identity, voiceEmbeddings[identity] ?? phrase.voiceEmbedding)
        }
        checkpoint()
    }

    func assignPersonToLine(phrase: LiveTranscriptPhrase, personID: UUID?) {
        guard knownRecognitionSessions.contains(phrase.session) else { return }
        draft?.assignPerson(personID, for: phrase)
        checkpoint()
    }

    func begin(
        meetingID: UUID, language: String, directory: URL, sources: [LiveAudioSource],
        sink: LiveAudioSink, enabled: Bool, diarizationProvider: ServiceProvider? = nil,
        speakerLabelsEnabled: Bool = false, speakerRecognitionEnabled: Bool = false,
        people: @escaping () -> [Person] = { [] },
        enrollVoice: ((UUID?, UUID, TypedVoiceEmbedding?) -> Void)? = nil
    ) {
        transcriptionIssue = nil
        transcriptionFailures = []
        checkpointIssue = nil
        checkpointWriter = LiveTranscriptCheckpointWriter()
        checkpointGeneration = UUID()
        journalIssue = nil
        speakerAnalysisIssue = nil
        voiceMatchingIssue = nil
        voiceMatchingError = nil
        acceptedGenerations = []
        knownRecognitionSessions = []
        acceptedSpeakerGenerations = []
        pendingSpeakerFinalizations = [:]
        self.diarizationProvider = diarizationProvider
        peopleProvider = people
        self.enrollVoice = enrollVoice
        modelObservation = LocalModelManager.shared.$states.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sink != nil else { return }
                if self.waitingForSpeakerModel, self.speakerLabelsEnabled,
                    let raw = self.diarizationProvider?.model, let model = LocalModelID(rawValue: raw),
                    LocalModelManager.shared.state(for: model).phase == .ready
                {
                    self.setSpeakerLabelsEnabled(self.speakerLabelsEnabled)
                }
                if self.waitingForVoiceModel, self.speakerRecognitionEnabled,
                    LocalModelManager.shared.state(for: .voiceEmbedding).phase == .ready
                {
                    self.setSpeakerRecognitionEnabled(true)
                }
            }
        }
        voiceEmbeddings = [:]
        voiceCandidates = [:]
        pendingFinalizations = [:]
        finalizationFailed = false
        boundaries = [:]
        self.enabled = false
        self.directory = directory
        self.sources = sources
        self.sink = sink
        draft = LiveTranscriptDraft(meetingID: meetingID, locale: language)
        setEnabled(enabled)
        self.speakerRecognitionEnabled = false
        setSpeakerLabelsEnabled(speakerLabelsEnabled)
        setSpeakerRecognitionEnabled(speakerRecognitionEnabled)
    }

    func setSpeakerLabelsEnabled(_ value: Bool) {
        speakerLabelsEnabled = value
        defer { if speakerRecognitionEnabled { setSpeakerRecognitionEnabled(true) } }
        guard value else {
            waitingForSpeakerModel = false
            detachSpeakerSession()
            speakerAnalysisIssue = nil
            speakerLabelStatus = "Live speaker labels are off."
            return
        }
        guard speakerProvider == nil else {
            if speakerAnalysisReady {
                speakerLabelStatus =
                    value ? "Live speaker labels · Nemotron" : "Speaker analysis is running for recognition."
            }
            return
        }
        waitingForSpeakerModel = false
        speakerAnalysisIssue = nil
        speakerGeneration = UUID()
        let token = speakerGeneration
        guard let provider = diarizationProvider, provider.supports(.liveDiarization),
            let model = LocalModelID(rawValue: provider.model), model.nemotronPreset != nil, let sink
        else {
            speakerLabelStatus = "Choose a Nemotron provider in Settings to use live speaker labels."
            speakerAnalysisIssue = speakerLabelStatus
            return
        }
        if UIPreview.enabled {
            speakerLabelStatus = "Synthetic speaker labels · No model is running."
            return
        }
        acceptedSpeakerGenerations.insert(token)
        speakerLabelStatus = "Preparing live speaker labels…"
        let runtime = LocalLiveDiarization()
        speakerProvider = runtime
        let boundaries = Dictionary(
            uniqueKeysWithValues: (draft?.speakerTimeline?.cursors ?? []).map { ($0.source, $0.end) })
        speakerStartup = Task { [self] in
            do {
                try await runtime.start(
                    model: model, sources: sources, sink: sink, boundaries: boundaries,
                    event: { [weak self] event in await self?.receiveSpeakerEvent(event, token: token) },
                    gap: { [weak self] gap in await self?.receiveSpeakerGap(gap, token: token) },
                    failure: { [weak self] message in await self?.speakerFailure(message, token: token) },
                    sample: { [weak self] sample in await self?.receiveVoiceSample(sample, token: token) })
                guard token == speakerGeneration, !Task.isCancelled else {
                    await runtime.cancel()
                    return
                }
                speakerAnalysisReady = true
                speakerLabelStatus =
                    speakerLabelsEnabled
                    ? "Live speaker labels · Nemotron" : "Speaker analysis is running for recognition."
                refreshVoiceReadyStatus()
                openLocalDataEvent(
                    token, targetID: provider.id, targetName: provider.name,
                    purpose: "Live speaker analysis", bodies: ["Live audio frames", "Source-scoped speaker activity"])
            }
            catch {
                await runtime.cancel()
                guard token == speakerGeneration, !Task.isCancelled else { return }
                speakerProvider = nil
                acceptedSpeakerGenerations.remove(token)
                speakerAnalysisReady = false
                refreshVoiceReadyStatus()
                waitingForSpeakerModel = LocalModelManager.shared.state(for: model).phase != .ready
                speakerLabelStatus =
                    "Live speaker labels are unavailable. \(error.localizedDescription) Recording continues."
                speakerAnalysisIssue = speakerLabelStatus
            }
        }
    }

    private func detachSpeakerSession() {
        speakerAnalysisReady = false
        speakerStartup?.cancel()
        speakerStartup = nil
        guard let runtime = speakerProvider else { return }
        let token = speakerGeneration
        speakerProvider = nil
        pendingSpeakerFinalizations[token] = Task {
            let completed = await LiveFinishRace.run(seconds: 5) { await runtime.finish() }
            if !completed { Task { await runtime.cancel() } }
            acceptedSpeakerGenerations.remove(token)
            closeDataEvent(token)
            pendingSpeakerFinalizations.removeValue(forKey: token)
            return completed
        }
    }

    private func receiveSpeakerEvent(_ event: LiveSpeakerEvent, token: UUID) {
        guard acceptedSpeakerGenerations.contains(token) else { return }
        if draft?.speakerTimeline == nil { draft?.speakerTimeline = LiveSpeakerTimeline() }
        guard draft?.speakerTimeline?.accept(event) == true else { return }
        if event.final || Date().timeIntervalSince(lastSpeakerCheckpoint) >= 2 {
            checkpoint()
            lastSpeakerCheckpoint = Date()
        }
    }

    private func receiveSpeakerGap(_ gap: LiveTranscriptGap, token: UUID) {
        guard acceptedSpeakerGenerations.contains(token) else { return }
        if draft?.speakerTimeline == nil { draft?.speakerTimeline = LiveSpeakerTimeline() }
        draft?.speakerTimeline?.gaps.append(gap)
        checkpoint()
    }

    private func speakerFailure(_ message: String, token: UUID) {
        guard token == speakerGeneration else { return }
        speakerAnalysisReady = false
        speakerLabelStatus = message
        speakerAnalysisIssue = message
        refreshVoiceReadyStatus()
    }

    private func refreshVoiceReadyStatus() {
        guard speakerRecognitionEnabled else { return }
        if let error = voiceMatchingError {
            let message = LiveSpeakerModelDiagnostics.voiceFailure(
                phase: LocalModelManager.shared.state(for: .voiceEmbedding).phase,
                error: error, labelsAvailable: speakerAnalysisReady)
            speakerRecognitionStatus = message
            voiceMatchingIssue = message
            return
        }
        guard voiceWorker != nil else { return }
        speakerRecognitionStatus =
            speakerAnalysisReady
            ? "Speaker association is ready. Waiting for clear speech."
            : "Speaker association is waiting for Nemotron speaker analysis. Check its provider and model in Settings."
    }

    func setSpeakerRecognitionEnabled(_ value: Bool) {
        voiceMatchingIssue = nil
        voiceMatchingError = nil
        waitingForVoiceModel = false
        closeDataEvent(voiceGeneration)
        voiceGeneration = UUID()
        voiceStartup?.cancel()
        voiceWork?.cancel()
        voiceWork = nil
        if let worker = voiceWorker { Task { await worker.cancel() } }
        voiceWorker = nil
        speakerRecognitionEnabled = value
        guard value else {
            speakerRecognitionStatus = "Speaker association is off."
            return
        }
        guard speakerLabelsEnabled else {
            speakerRecognitionStatus = "Speaker association is waiting for speaker labeling."
            return
        }
        guard !UIPreview.enabled else {
            speakerRecognitionStatus = "Synthetic people · No speaker association is running."
            return
        }
        guard let provider = diarizationProvider, provider.supports(.liveDiarization),
            let model = LocalModelID(rawValue: provider.model), model.nemotronPreset != nil
        else {
            speakerRecognitionStatus = "Choose a Nemotron provider in Settings for live speaker association."
            return
        }
        let token = voiceGeneration
        let worker = LiveVoiceEmbeddingWorker()
        speakerRecognitionStatus = "Preparing speaker association…"
        voiceStartup = Task {
            do {
                try await worker.prepare()
                guard token == voiceGeneration, !Task.isCancelled else {
                    await worker.cancel()
                    return
                }
                voiceWorker = worker
                refreshVoiceReadyStatus()
                openLocalDataEvent(
                    token, targetID: ThisMacProvider.id, targetName: "This Mac",
                    purpose: "Live speaker association", bodies: ["Clear speech excerpts", "Typed voice embeddings"])
            }
            catch {
                await worker.cancel()
                guard token == voiceGeneration, !Task.isCancelled else { return }
                waitingForVoiceModel = LocalModelManager.shared.state(for: .voiceEmbedding).phase != .ready
                voiceMatchingError = error
                let message = LiveSpeakerModelDiagnostics.voiceFailure(
                    phase: LocalModelManager.shared.state(for: .voiceEmbedding).phase,
                    error: error, labelsAvailable: speakerAnalysisReady)
                speakerRecognitionStatus = message
                voiceMatchingIssue = message
            }
        }
    }

    private func receiveVoiceSample(_ sample: LiveSpeakerAudioSample, token: UUID) {
        guard acceptedSpeakerGenerations.contains(token), speakerLabelsEnabled, speakerRecognitionEnabled,
            let worker = voiceWorker, voiceWork == nil
        else { return }
        let voiceToken = voiceGeneration
        voiceWork = Task {
            defer { if voiceGeneration == voiceToken { voiceWork = nil } }
            do {
                guard let embedding = try await worker.extract(sample), !Task.isCancelled,
                    voiceGeneration == voiceToken, acceptedSpeakerGenerations.contains(token)
                else { return }
                voiceMatchingIssue = nil
                voiceEmbeddings[sample.speakerID] = embedding
                draft?.speakerTimeline?.retainEmbedding(embedding, for: sample.speakerID)
                checkpoint()
                guard let speaker = draft?.speakerTimeline?.speakers.first(where: { $0.id == sample.speakerID }) else {
                    return
                }
                if speaker.manuallyAssigned {
                    if let personID = speaker.personID { enrollVoice?(personID, speaker.id, embedding) }
                    return
                }
                guard let match = SpeakerRecognition.match(embedding: embedding, people: peopleProvider()) else {
                    voiceCandidates.removeValue(forKey: speaker.id)
                    return
                }
                let previous = voiceCandidates[speaker.id]
                let count = previous?.person == match.personID ? (previous?.count ?? 0) + 1 : 1
                voiceCandidates[speaker.id] = (match.personID, count)
                if count >= 3 {
                    draft?.speakerTimeline?.assign(match.personID, to: speaker.id, manual: false)
                    speakerRecognitionStatus = "Speaker association updated a matching voice."
                    checkpoint()
                }
            }
            catch {
                guard voiceGeneration == voiceToken, !Task.isCancelled else { return }
                speakerRecognitionStatus = "Couldn’t match this voice. Anonymous speaker labels are kept."
                voiceMatchingIssue = speakerRecognitionStatus
            }
        }
    }

    func seedPreview(meetingID: UUID, directory: URL) {
        begin(
            meetingID: meetingID, language: "en", directory: directory,
            sources: [.microphone, .system], sink: LiveAudioSink(), enabled: true)
        let microphoneSession = UUID()
        let systemSession = UUID()
        knownRecognitionSessions.formUnion([microphoneSession, systemSession])
        for index in 0..<18 {
            let source: LiveAudioSource = index.isMultiple(of: 2) ? .system : .microphone
            draft?.accept(
                .init(
                    session: source == .system ? systemSession : microphoneSession,
                    source: source, start: Double(index * 5 + 1), end: Double(index * 5 + 4),
                    text: index == 8
                        ? "The draft includes the schedule, open questions, and the next review. We can check each section together and record any changes before sharing it."
                        : (index.isMultiple(of: 2) ? "Let’s review the next item." : "I’ll add that to the draft."),
                    locale: "en-AU"))
        }
        partials = [
            .init(
                session: systemSession, source: .system, start: 91, end: 94,
                text: "The next review will cover…", locale: "en-AU", recognizedFinal: false),
            .init(
                session: microphoneSession, source: .microphone, start: 94, end: 97,
                text: "I’ll update the schedule…", locale: "en-AU", recognizedFinal: false),
        ]
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
            transcriptionIssue = status
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
                        journalIssue = nil
                    }
                    catch {
                        journalIssue = "Couldn’t save the live processing data event."
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
        pendingFinalizations[token] = Task {
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
        modelObservation = nil
        waitingForSpeakerModel = false
        waitingForVoiceModel = false
        detachSpeakerSession()
        let speakerFinishes = Array(pendingSpeakerFinalizations.values)
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
        if speakerLabelsEnabled || draft?.speakerTimeline != nil {
            var labelsComplete = !speakerFinishes.isEmpty
            for task in speakerFinishes {
                if !(await task.value) { labelsComplete = false }
            }
            draft?.speakerLabelsComplete = labelsComplete && (draft?.speakerTimeline?.gaps.isEmpty ?? false)
        }
        acceptedSpeakerGenerations = []
        closeDataEvent(voiceGeneration)
        voiceGeneration = UUID()
        voiceStartup?.cancel()
        voiceWork?.cancel()
        if let worker = voiceWorker { Task { await worker.cancel() } }
        voiceWorker = nil
        if !(draft?.gaps.isEmpty ?? true) { draft?.complete = false }
        if finalizationFailed {
            draft?.complete = false
            status = "Live draft saved. The last phrase may be incomplete."
        }
        acceptedGenerations = []
        closeDataEvent(generation)
        generation = UUID()
        partials = []
        checkpoint()
        await flushCheckpoint()
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
        checkpoint()
    }
    func receive(_ value: LiveTranscriptPhrase, final: Bool, token: UUID) {
        guard acceptedGenerations.contains(token) else { return }
        knownRecognitionSessions.insert(value.session)
        var value = value
        value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.preservingIdentity(from: (draft?.phrases ?? []) + partials)
        value.recognizedFinal = final
        partials = LiveTranscriptPhrase.replacingPartials(
            partials, with: value, final: final || token != generation)
        if final {
            draft?.accept(value)
            checkpoint()
        }
    }
    private func checkpoint() {
        guard let draft, let directory else { return }
        let meetingID = draft.meetingID
        let checkpointGeneration = self.checkpointGeneration
        checkpointWriter.submit(draft, at: directory) { [weak self] issue in
            guard let self, self.draft?.meetingID == meetingID, self.checkpointGeneration == checkpointGeneration else {
                return
            }
            if self.checkpointIssue != issue { self.checkpointIssue = issue }
            if let issue, self.status != issue { self.status = issue }
        }
    }

    /// Waits for the latest accepted snapshot, including its storage error report.
    func flushCheckpoint() async { await checkpointWriter.flush() }
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
            journalIssue = nil
        }
        catch {
            journalIssue = "Couldn’t save the live processing data event."
        }
    }

    private func closeDataEvent(_ token: UUID) {
        guard var event = dataEvents.removeValue(forKey: token), let directory else { return }
        event.dataFlow.endedAt = Date()
        do {
            try DataEventJournal.append(event, directory: directory)
            journalIssue = nil
        }
        catch {
            journalIssue = "Couldn’t save the live processing data event."
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

enum LiveSpeakerModelDiagnostics {
    static func voiceFailure(phase: LocalModelPhase, error: Error, labelsAvailable: Bool) -> String {
        let continued = labelsAvailable ? " Anonymous speaker labels continue." : ""
        guard let modelError = error as? LocalModelError, case .unavailable = modelError else {
            return "Speaker association is unavailable. \(error.localizedDescription)" + continued
        }
        let action: String
        switch phase {
        case .downloading, .verifying, .preparing:
            action = "Speaker association is waiting for the Speaker Association Model to finish setup."
        case .failed:
            action =
                "The Speaker Association Model couldn’t be prepared. Open the speaker association provider in Settings → Service Providers and choose Retry or Verify under Speaker Association Model."
        case .missing, .unverified, .cancelled, .ready:
            action =
                "Speaker association needs a separate model. Open the speaker association provider in Settings → Service Providers and download or verify Speaker Association Model."
        }
        return action + continued
    }
}
