import Combine
import CryptoKit
import Foundation

struct VoicePreparationCapability: Equatable {
    let type: EmbeddingType?
    let unavailableReason: String?
    var isAvailable: Bool { type != nil }
}

enum VoicePreparationState: String, Codable {
    case queued, running, paused, completed, failed, cancelled
}

struct VoiceDiscoveryInput: Codable, Equatable {
    var meetingID: UUID
    var audioFiles: [String]
    var audioRevisions: [String: String]
}

/// Each saved item is independently resumable. Completed representations are reusable
/// across providers that declare exactly the same embedding space.
struct VoicePreparationJob: Identifiable, Codable, Equatable {
    var id = UUID()
    var providerID: UUID
    var providerName: String
    var type: EmbeddingType
    var discover: Bool
    var exampleIDs: [UUID]
    var discoveryInputs: [VoiceDiscoveryInput] = []
    var completedRecordingIDs: [UUID] = []
    /// A full analysis receipt is stronger than reusing one already-known voice.
    var fullyAnalyzedRecordingIDs: [UUID]?
    var completedExampleIDs: [UUID] = []
    var failures: [String: String] = [:]
    var state: VoicePreparationState = .queued
    var createdAt = Date()
    var attentionAcknowledged: Bool?
    var timeline: [TaskAttemptEvent]?
    var progress: String {
        let examples = "\(completedExampleIDs.count) of \(exampleIDs.count) voice examples prepared"
        guard !discoveryInputs.isEmpty else { return examples }
        return "\(completedRecordingIDs.count) of \(discoveryInputs.count) recordings analyzed · \(examples)"
    }
}

protocol VoiceExampleEmbeddingExtracting: Sendable {
    func finish() async
    func extract(example: VoiceExample, directory: URL, type: EmbeddingType) async throws -> TypedVoiceEmbedding
}

protocol VoiceRecordingDiscovering: Sendable {
    func finish() async
    func discover(files: [URL]) async throws -> LocalDiarizationResult
}

extension VoiceExampleEmbeddingExtracting { func finish() async {} }
extension VoiceRecordingDiscovering { func finish() async {} }

@MainActor
final class VoiceLibraryPreparation: ObservableObject {
    private let library: VoiceLibraryStore
    private let extractor: (any VoiceExampleEmbeddingExtracting)?
    private let discoverer: (any VoiceRecordingDiscovering)?
    private let inventoryReader = VoiceDiscoverySourceReader()
    private let people: () -> [Person]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var retiringRuns: [UUID: Task<Void, Never>] = [:]
    var pendingRunCount: Int { tasks.count + retiringRuns.count }
    private var recordingPausedJobs: [UUID] = []
    private var runTokens: [UUID: UUID] = [:]
    @Published private(set) var errorMessage: String?

    init(
        library: VoiceLibraryStore, extractor: (any VoiceExampleEmbeddingExtracting)? = nil,
        discoverer: (any VoiceRecordingDiscovering)? = nil,
        people: @escaping () -> [Person] = { [] }
    ) {
        self.library = library
        self.extractor = extractor
        self.discoverer = discoverer
        self.people = people
        // A process exit cannot leave a task appearing to run after reopening.
        var recovered = library.jobs
        for index in recovered.indices where recovered[index].state == .running || recovered[index].state == .queued {
            let previous = recovered[index]
            recovered[index].state = .paused
            recovered[index].recordTransition(from: previous)
            if let last = recovered[index].timeline?.indices.last {
                recovered[index].timeline?[last].reason = "Paused after interruption"
            }
        }
        if recovered != library.jobs { _ = library.setJobs(recovered) }
    }

    static func capability(for provider: ServiceProvider) -> VoicePreparationCapability {
        if provider.kind == .runpod {
            return .init(
                type: nil,
                unavailableReason: "RunPod does not provide a compatible voice extraction model. Use a local provider.")
        }
        guard provider.isEnabled, provider.kind.isLocalSpeaker else {
            return .init(type: nil, unavailableReason: "This provider does not support preparing voice examples.")
        }
        switch provider.kind {
        case .speakerLabeling:
            return .init(type: .community1, unavailableReason: nil)
        default:
            return .init(type: nil, unavailableReason: "This provider has no compatible voice extraction adapter.")
        }
    }

    /// Selection can repair old source references without starting a model or scanning the library.
    func findPlayableExample(exampleID: UUID, directory: URL) async -> VoiceExample? {
        guard await library.awaitReady() else {
            errorMessage = library.errorMessage
            return nil
        }
        guard let original = library.examples.first(where: { $0.id == exampleID }) else { return nil }
        errorMessage = nil
        do {
            let snapshot = try await inventoryReader.read(meetingID: original.meetingID, folder: directory)
            try Task.checkCancellation()
            guard
                let resolved = library.resolveLegacyExample(
                    exampleID: exampleID, meeting: snapshot.meeting, directory: directory)
            else {
                errorMessage = library.errorMessage
                return nil
            }
            errorMessage = library.availabilityReason(for: resolved)
            return resolved
        }
        catch is CancellationError { return nil }
        catch {
            errorMessage = "Couldn’t read the source recording. \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func start(
        provider: ServiceProvider, meetings: [Meeting], directory: @escaping (UUID) -> URL, discover: Bool = false
    ) -> UUID? {
        guard library.isLoaded else {
            errorMessage = "The voice library is still opening. Wait for it to finish, then try again."
            return nil
        }
        guard let type = Self.capability(for: provider).type else {
            errorMessage = Self.capability(for: provider).unavailableReason
            return nil
        }
        guard tasks.isEmpty else {
            errorMessage = "Pause the current voice preparation before starting another."
            return nil
        }
        errorMessage = nil
        let meetingIDs = Set(meetings.map(\.id))
        let examples = library.examples.filter {
            !$0.excluded && meetingIDs.contains($0.meetingID)
                && (discover || $0.review == .confirmed)
        }
        let inputs: [VoiceDiscoveryInput] =
            discover
            ? meetings.compactMap { meeting in
                guard !meeting.audioFiles.isEmpty else { return nil }
                return .init(meetingID: meeting.id, audioFiles: meeting.audioFiles, audioRevisions: [:])
            } : []
        var job = VoicePreparationJob(
            providerID: provider.id, providerName: provider.name, type: type, discover: discover,
            exampleIDs: examples.map(\.id), discoveryInputs: inputs)
        job.timeline = [.init(kind: .queued, date: job.createdAt, reason: nil)]
        guard library.setJobs(library.jobs + [job]) else { return nil }
        resume(jobID: job.id, directory: directory)
        return job.id
    }

    func discard(jobID: UUID) {
        guard let job = library.jobs.first(where: { $0.id == jobID }), job.state != .queued && job.state != .running
        else { return }
        recordingPausedJobs.removeAll { $0 == jobID }
        _ = library.setJobs(library.jobs.filter { $0.id != jobID })
    }

    func dismissAlert(jobID: UUID) {
        update(jobID) { $0.attentionAcknowledged = true }
    }

    func pause(jobID: UUID, reason: String? = nil) {
        if reason == nil { recordingPausedJobs.removeAll { $0 == jobID } }
        let token = runTokens.removeValue(forKey: jobID)
        if let task = tasks.removeValue(forKey: jobID) {
            task.cancel()
            if let token { retiringRuns[token] = task }
        }
        update(jobID) { $0.state = .paused }
        if let reason {
            update(jobID) { job in
                if let last = job.timeline?.indices.last { job.timeline?[last].reason = reason }
            }
        }
    }

    func cancel(jobID: UUID) {
        recordingPausedJobs.removeAll { $0 == jobID }
        let token = runTokens.removeValue(forKey: jobID)
        if let task = tasks.removeValue(forKey: jobID) {
            task.cancel()
            if let token { retiringRuns[token] = task }
        }
        update(jobID) { $0.state = .cancelled }
    }

    func shutdown() async {
        recordingPausedJobs = []
        let pending = Array(tasks.values) + Array(retiringRuns.values)
        for id in Array(tasks.keys) { pause(jobID: id) }
        for task in pending { await task.value }
    }

    func suspendForRecording() {
        let running = library.jobs.filter { $0.state == .running && tasks[$0.id] != nil }.map(\.id)
        recordingPausedJobs = running
        for id in running { pause(jobID: id, reason: "Paused for recording") }
    }

    func resumeAfterRecording(directory: @escaping (UUID) -> URL) {
        let paused = recordingPausedJobs
        recordingPausedJobs = []
        for id in paused where library.jobs.first(where: { $0.id == id })?.state == .paused {
            resume(jobID: id, directory: directory)
        }
    }

    func resume(jobID: UUID, directory: @escaping (UUID) -> URL) {
        guard tasks.isEmpty, let job = library.jobs.first(where: { $0.id == jobID }), job.state != .completed else {
            return
        }
        guard update(jobID, { $0.state = .running }) else { return }
        let token = UUID()
        runTokens[jobID] = token
        let retiring = Array(retiringRuns.values)
        tasks[jobID] = Task { [weak self] in
            guard let self else { return }
            defer {
                retiringRuns.removeValue(forKey: token)
                if runTokens[jobID] == token {
                    tasks.removeValue(forKey: jobID)
                    runTokens.removeValue(forKey: jobID)
                }
            }
            for previous in retiring { await previous.value }
            guard !Task.isCancelled, runTokens[jobID] == token else { return }
            await run(jobID: jobID, directory: directory)
        }
    }

    /// Exposed internally for deterministic tests; production work is started by resume.
    func run(jobID: UUID, directory: (UUID) -> URL) async {
        guard await library.awaitReady() else {
            errorMessage = library.errorMessage
            return
        }
        // A run owns its sessions. Pause/resume cannot hand an old cancelled worker
        // to the replacement run, and cleanup completes before a run releases its owner.
        let extractor = extractor ?? LocalVoiceExampleExtractor()
        let discoverer = discoverer ?? LocalVoiceRecordingDiscoverer()
        await process(jobID: jobID, directory: directory, extractor: extractor, discoverer: discoverer)
        await extractor.finish()
        await discoverer.finish()
    }

    private func process(
        jobID: UUID, directory: (UUID) -> URL,
        extractor: any VoiceExampleEmbeddingExtracting, discoverer: any VoiceRecordingDiscovering
    ) async {
        await discoverRecordings(jobID: jobID, directory: directory, discoverer: discoverer)
        guard let job = library.jobs.first(where: { $0.id == jobID }), job.state == .running else { return }
        for exampleID in job.exampleIDs {
            guard !Task.isCancelled,
                library.jobs.first(where: { $0.id == jobID })?.state == .running
            else { return }
            if library.jobs.first(where: { $0.id == jobID })?.completedExampleIDs.contains(exampleID) == true {
                continue
            }
            guard let metadata = library.examples.first(where: { $0.id == exampleID }), !metadata.excluded else {
                if !complete(exampleID, jobID: jobID) { return }
                continue
            }
            guard let example = library.hydratedExample(id: exampleID) else {
                guard
                    update(jobID, { $0.failures[exampleID.uuidString] = "Couldn’t read saved voice representations." })
                else { return }
                continue
            }
            if example.voiceEmbeddings.contains(where: { $0.type == job.type && $0.isValid }) {
                if !complete(exampleID, jobID: jobID) { return }
                continue
            }
            guard library.audioIsCurrent(metadata) else {
                guard
                    update(
                        jobID,
                        { $0.failures[exampleID.uuidString] = "Audio is unavailable for this model’s preparation." })
                else { return }
                continue
            }
            do {
                let representation = try await extractor.extract(
                    example: example, directory: directory(example.meetingID), type: job.type)
                try Task.checkCancellation()
                guard representation.type == job.type, representation.isValid else {
                    throw ServiceError("The provider returned an incompatible voice representation.")
                }
                // Review, exclusion, and audio changes during extraction invalidate its snapshot.
                guard let current = library.examples.first(where: { $0.id == exampleID }), !current.excluded else {
                    if !complete(exampleID, jobID: jobID) { return }
                    continue
                }
                guard current.audioFile == example.audioFile, current.start == example.start,
                    current.end == example.end, current.audioRevision == example.audioRevision,
                    library.audioIsCurrent(current)
                else { throw ServiceError("The source audio changed during preparation. Review a new example.") }
                guard library.addRepresentation(exampleID: exampleID, embedding: representation),
                    complete(exampleID, jobID: jobID)
                else { return }
            }
            catch is CancellationError { return }
            catch {
                guard update(jobID, { $0.failures[exampleID.uuidString] = error.localizedDescription }) else { return }
            }
        }
        guard !Task.isCancelled else { return }
        if job.discover { groupUnassigned(type: job.type, exampleIDs: Set(job.exampleIDs)) }
        library.suggestReviewedPeople(from: people())
        update(jobID) { $0.state = $0.failures.isEmpty ? .completed : .failed }
    }

    private func discoverRecordings(jobID: UUID, directory: (UUID) -> URL, discoverer: any VoiceRecordingDiscovering)
        async
    {
        guard let job = library.jobs.first(where: { $0.id == jobID }), job.discover else { return }
        for var input in job.discoveryInputs {
            await Task.yield()
            guard !Task.isCancelled, library.jobs.first(where: { $0.id == jobID })?.state == .running else { return }
            if library.jobs.first(where: { $0.id == jobID })?.completedRecordingIDs.contains(input.meetingID) == true {
                continue
            }
            let failureKey = "recording-" + input.meetingID.uuidString
            do {
                let root = directory(input.meetingID).standardizedFileURL.resolvingSymlinksInPath()
                let saved = try await inventoryReader.read(meetingID: input.meetingID, folder: root)
                try Task.checkCancellation()
                if input.audioRevisions.isEmpty {
                    input.audioRevisions = saved.revisions
                    guard
                        update(
                            jobID,
                            { task in
                                if let index = task.discoveryInputs.firstIndex(where: {
                                    $0.meetingID == input.meetingID
                                }) {
                                    task.discoveryInputs[index] = input
                                }
                            })
                    else { return }
                }
                let files = try input.audioFiles.map { file in
                    let url = root.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
                    guard url.path.hasPrefix(root.path + "/"), let revision = input.audioRevisions[file],
                        VoiceLibraryStore.revision(url: url) == revision
                    else { throw ServiceError("The source audio changed or is unavailable. Start a new voice search.") }
                    return url
                }
                guard library.ingest(meeting: saved.meeting, directory: root) else { return }
                let existing = library.examples.filter { $0.meetingID == input.meetingID && library.audioIsCurrent($0) }
                let savedSpeakers = Set(saved.meeting.speakers.filter(\.canAssignPerson).map(\.id))
                let existingSpeakers = Set(existing.map(\.speakerID))
                let existingFiles = Set(existing.compactMap(\.audioFile))
                let coversSavedLabels =
                    !savedSpeakers.isEmpty && savedSpeakers.isSubset(of: existingSpeakers)
                    && Set(input.audioFiles).isSubset(of: existingFiles)
                let hasFullAnalysis = library.jobs.contains { previous in
                    previous.type == job.type
                        && previous.fullyAnalyzedRecordingIDs?.contains(input.meetingID) == true
                        && previous.discoveryInputs.contains { original in
                            original.meetingID == input.meetingID
                                && Set(original.audioFiles) == Set(input.audioFiles)
                                && original.audioRevisions == input.audioRevisions
                        }
                }
                if coversSavedLabels || hasFullAnalysis {
                    guard finishRecording(input, examples: existing, jobID: jobID, failureKey: failureKey) else {
                        return
                    }
                    continue
                }
                let result = try await discoverer.discover(files: files)
                try Task.checkCancellation()
                guard
                    zip(input.audioFiles, files).allSatisfy({
                        input.audioRevisions[$0.0] == VoiceLibraryStore.revision(url: $0.1)
                    })
                else { throw ServiceError("The source audio changed during analysis. Start a new voice search.") }
                let candidates: [VoiceExample] = result.speakers.compactMap { speaker in
                    guard let range = speaker.voiceSampleRange, range.isValid,
                        input.audioFiles.contains(range.audioFile),
                        let embedding = speaker.voiceEmbedding, embedding.isValid, embedding.type == job.type,
                        let revision = input.audioRevisions[range.audioFile]
                    else { return nil }
                    let identity = Self.discoveryIdentity(
                        meetingID: input.meetingID, range: range, revision: revision, model: result.modelRevision)
                    return .init(
                        id: identity, meetingID: input.meetingID, speakerID: identity, source: range.source,
                        audioFile: range.audioFile, audioRevision: revision, start: range.start, end: range.end,
                        embeddings: [embedding], groupID: identity, origin: .discovery)
                }
                guard library.upsert(candidates),
                    finishRecording(
                        input, examples: existing + candidates, jobID: jobID, failureKey: failureKey,
                        fullyAnalyzed: true)
                else { return }
            }
            catch is CancellationError { return }
            catch let error as VoiceDiscoveryUnavailable {
                update(jobID) {
                    $0.failures[failureKey] = error.localizedDescription
                    $0.state = .failed
                }
                return
            }
            catch {
                guard update(jobID, { $0.failures[failureKey] = error.localizedDescription }) else { return }
            }
        }
    }

    private func finishRecording(
        _ input: VoiceDiscoveryInput, examples: [VoiceExample], jobID: UUID, failureKey: String,
        fullyAnalyzed: Bool = false
    ) -> Bool {
        update(jobID) {
            if !$0.completedRecordingIDs.contains(input.meetingID) { $0.completedRecordingIDs.append(input.meetingID) }
            if fullyAnalyzed {
                $0.fullyAnalyzedRecordingIDs = Array(Set(($0.fullyAnalyzedRecordingIDs ?? []) + [input.meetingID]))
            }
            $0.failures.removeValue(forKey: failureKey)
            for example in examples where !$0.exampleIDs.contains(example.id) { $0.exampleIDs.append(example.id) }
        }
    }

    /// Replaying a completed model result after a crash cannot duplicate evidence.
    private static func discoveryIdentity(meetingID: UUID, range: VoiceSampleRange, revision: String, model: String)
        -> UUID
    {
        let key = "\(meetingID)|\(range.audioFile)|\(range.start)|\(range.end)|\(revision)|\(model)"
        let hex = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map {
            String(
                hex[
                    hex.index(
                        hex.startIndex, offsetBy: $0.lowerBound)..<hex.index(hex.startIndex, offsetBy: $0.upperBound)])
        }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }

    @discardableResult
    private func complete(_ exampleID: UUID, jobID: UUID) -> Bool {
        update(jobID) {
            if !$0.completedExampleIDs.contains(exampleID) { $0.completedExampleIDs.append(exampleID) }
            $0.failures.removeValue(forKey: exampleID.uuidString)
        }
    }

    @discardableResult
    private func update(_ jobID: UUID, _ change: (inout VoicePreparationJob) -> Void) -> Bool {
        var jobs = library.jobs
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return false }
        let previous = jobs[index]
        change(&jobs[index])
        jobs[index].recordTransition(from: previous)
        return library.setJobs(jobs)
    }

    /// Grouping offers review candidates only; it never confirms a person or trains a profile.
    /// Complete-link comparison avoids chains of weakly related voices joining a group.
    private func groupUnassigned(type: EmbeddingType, exampleIDs: Set<UUID>) {
        defer { library.releaseRepresentations() }
        var groups: [[VoiceExample]] = []
        let candidates = library.hydratedExamples(ids: exampleIDs).filter {
            exampleIDs.contains($0.id) && !$0.isReviewed && !$0.manuallyGrouped && $0.review == .unassigned
                && $0.rejectedPersonIDs.isEmpty && $0.personID == nil
                && $0.voiceEmbeddings.contains(where: { $0.type == type && $0.isValid })
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        for example in candidates {
            guard let vector = example.voiceEmbeddings.first(where: { $0.type == type && $0.isValid }) else { continue }
            let index = groups.firstIndex { group in
                group.allSatisfy { other in
                    guard other.meetingID != example.meetingID,
                        let value = other.voiceEmbeddings.first(where: { $0.type == type && $0.isValid }),
                        let score = SpeakerRecognition.similarity(vector.values, value.values)
                    else { return false }
                    return score >= 0.95
                }
            }
            if let index {
                groups[index].append(example)
            }
            else {
                groups.append([example])
            }
        }
        for group in groups where group.count > 1 && Set(group.map(\.groupID)).count > 1 {
            _ = library.groupSuggestions(ids: Set(group.map(\.id)))
        }
    }
}

extension MeetingStore {
    /// Page the disk inventory without replacing the meeting list's bounded cache.
    /// Stage workers read one recording at a time; the inventory retains no transcripts.
    func voicePreparationMeetings() async throws -> [Meeting] {
        guard await voiceLibrary.awaitReady() else {
            throw ServiceError(voiceLibrary.errorMessage ?? "Couldn’t open the voice library.")
        }
        guard !isChangingLibrary, let index = libraryIndex else {
            throw ServiceError("The meeting library is not ready. Try again after it finishes opening.")
        }
        let directory = dataDirectory
        let activeRecording = recordingID
        let inventoryTask = Task.detached(priority: .utility) {
            var result: [Meeting] = []
            var cursor: MeetingListEntry?
            while true {
                try Task.checkCancellation()
                let page = try index.page(after: cursor, limit: 100)
                guard !page.isEmpty else { break }
                for entry in page where entry.id != activeRecording {
                    try Task.checkCancellation()
                    var meeting = Meeting()
                    meeting.id = entry.id
                    meeting.createdAt = entry.createdAt
                    meeting.audioFiles = entry.audioFiles
                    result.append(meeting)
                }
                cursor = page.last
            }
            return result
        }
        let inventory = try await withTaskCancellationHandler {
            try await inventoryTask.value
        } onCancel: {
            inventoryTask.cancel()
        }
        guard dataDirectory == directory, !isChangingLibrary else {
            throw ServiceError("The meeting library changed. Start voice preparation again.")
        }
        return inventory.filter { $0.id != recordingID }
    }
}
