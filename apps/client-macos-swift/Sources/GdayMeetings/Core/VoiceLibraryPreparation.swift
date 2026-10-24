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

struct VoiceDiscoveryInput: Codable, Equatable, Sendable {
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
    var discoveryConfiguration: VoiceDiscoveryConfiguration?
    var completedExampleIDs: [UUID] = []
    var failures: [String: String] = [:]
    var state: VoicePreparationState = .queued
    var createdAt = Date()
    var attentionAcknowledged: Bool?
    var timeline: [TaskAttemptEvent]?
    /// Explicit phases keep failed discovery inputs from masking later example preparation.
    var progressPhase: String?
    var progressStartedAt: Date?
    var estimatedRemainingSeconds: Double?
    var outcomeTitle: String {
        switch state {
        case .queued: return "Queued"
        case .running: return discover ? "Scanning" : "Preparing"
        case .paused: return "Paused"
        case .cancelled: return "Cancelled"
        case .completed: return failures.isEmpty ? "Completed" : "Completed with Errors"
        case .failed:
            let exhausted = progressPhase == "Comparing voice examples"
            let hasResults = discoveryInputs.isEmpty ? !completedExampleIDs.isEmpty : !completedRecordingIDs.isEmpty
            return exhausted && hasResults && failures["configuration"] == nil ? "Completed with Errors" : "Failed"
        }
    }
    var progressDetails: TaskProgress {
        if progressPhase == "Comparing voice examples" {
            return TaskProgress(
                phase: "Comparing voice examples", startedAt: progressStartedAt ?? timeline?.last?.date ?? createdAt)
        }
        if progressPhase != "Preparing voice examples" && !discoveryInputs.isEmpty
            && completedRecordingIDs.count < discoveryInputs.count
        {
            return TaskProgress(
                phase: "Analysing recordings", completed: Double(completedRecordingIDs.count),
                total: Double(discoveryInputs.count), unit: "recordings",
                startedAt: progressStartedAt ?? timeline?.last?.date ?? createdAt)
        }
        return TaskProgress(
            phase: "Analysing voice excerpts", completed: Double(completedExampleIDs.count),
            total: Double(exampleIDs.count), unit: "voice excerpts",
            startedAt: progressStartedAt ?? timeline?.last?.date ?? createdAt,
            estimatedRemainingSeconds: state == .running ? estimatedRemainingSeconds : nil)
    }
    var progress: String {
        let examples = "\(completedExampleIDs.count) of \(exampleIDs.count) voice excerpts analysed"
        guard !discoveryInputs.isEmpty else { return examples }
        return "\(completedRecordingIDs.count) of \(discoveryInputs.count) recordings analysed · \(examples)"
    }
}

protocol VoiceExampleEmbeddingExtracting: Sendable {
    func finish() async
    func processingDuration() async -> Double?
    func extract(example: VoiceExample, directory: URL, type: EmbeddingType) async throws -> TypedVoiceEmbedding
}

protocol VoiceRecordingDiscovering: Sendable {
    func finish() async
    func configuration() async -> VoiceDiscoveryConfiguration
    func discover(files: [URL]) async throws -> LocalDiarizationResult
}

extension VoiceExampleEmbeddingExtracting {
    func finish() async {}
    func processingDuration() async -> Double? { nil }
}
extension VoiceRecordingDiscovering {
    func finish() async {}
}

@MainActor
final class VoiceLibraryPreparation: ObservableObject {
    private let library: VoiceLibraryStore
    private let performanceCache: TaskPerformanceCache?
    private let extractor: (any VoiceExampleEmbeddingExtracting)?
    private let referenceExtractor: (any VoiceExampleEmbeddingExtracting)?
    private let referenceWriteReady: (() async -> Bool)?
    private let referenceReadSamples: @Sendable (URL, VoiceSampleRange) throws -> [Float]
    private let discoverer: (any VoiceRecordingDiscovering)?
    private let inventoryReader = VoiceDiscoverySourceReader()
    private let discoveryCache = VoiceDiscoveryCache()
    private let people: () -> [Person]
    private let currentProvider: (() -> ServiceProvider?)?
    private let alternativePreparationAllowed: (() -> Bool)?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var retiringRuns: [UUID: Task<Void, Never>] = [:]
    var pendingRunCount: Int {
        tasks.count + retiringRuns.count + retiringAlternatives.count + referenceTasks.count
            + (alternativeTask == nil ? 0 : 1)
    }
    private var retiringReferences: [UUID: Task<Void, Never>] = [:]
    @Published private(set) var referenceTokens: [UUID: UUID] = [:]
    private var referenceTasks: [UUID: Task<Void, Never>] = [:]
    private var recordingPausedJobs: [UUID] = []
    private var runTokens: [UUID: UUID] = [:]
    private var alternativeRequest: UUID?
    private var alternativeTask: Task<VoiceAlternativeSampleResult, Error>?
    private var recordingSuspended = false
    private var retiringAlternatives: [UUID: Task<VoiceAlternativeSampleResult, Error>] = [:]
    @Published private(set) var errorMessage: String?

    init(
        library: VoiceLibraryStore, performanceCache: TaskPerformanceCache? = nil,
        extractor: (any VoiceExampleEmbeddingExtracting)? = nil,
        discoverer: (any VoiceRecordingDiscovering)? = nil,
        people: @escaping () -> [Person] = { [] },
        alternativePreparationAllowed: (() -> Bool)? = nil,
        currentProvider: (() -> ServiceProvider?)? = nil,
        referenceExtractor: (any VoiceExampleEmbeddingExtracting)? = nil,
        referenceWriteReady: (() async -> Bool)? = nil,
        referenceReadSamples: @escaping @Sendable (URL, VoiceSampleRange) throws -> [Float] = { url, range in
            try LocalVoiceExampleExtractor.readSamples(url: url, spans: range.supportSpans)
        }
    ) {
        self.library = library
        self.performanceCache = performanceCache
        self.extractor = extractor
        self.referenceWriteReady = referenceWriteReady
        self.referenceExtractor = referenceExtractor
        self.referenceReadSamples = referenceReadSamples
        self.discoverer = discoverer
        self.people = people
        self.currentProvider = currentProvider
        self.alternativePreparationAllowed = alternativePreparationAllowed
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
            return .init(type: CommunityVoiceEmbeddingExtractor.embeddingType, unavailableReason: nil)
        default:
            return .init(type: nil, unavailableReason: "This provider has no compatible voice extraction adapter.")
        }
    }

    static func resumeUnavailableReason(for job: VoicePreparationJob, provider: ServiceProvider? = nil) -> String? {
        guard job.type == CommunityVoiceEmbeddingExtractor.embeddingType else {
            return "This task uses an earlier voice model. Start a new scan to reuse compatible results."
        }
        if let provider {
            guard provider.id == job.providerID, capability(for: provider).type == job.type else {
                return "The selected provider changed. Start a new scan with the current provider."
            }
        }
        if let configuration = job.discoveryConfiguration, configuration != .community {
            return "The analysis model changed. Start a new scan to reuse compatible results."
        }
        return nil
    }

    /// Naming remains immediate. Bounded local audio checks run independently and
    /// only publish while the same explicit speaker identity is still current.
    func selectReference(meetingID: UUID, speakerID: UUID, personID: UUID, exampleID: UUID?, directory: URL) {
        cancelReference(speakerID: speakerID)
        guard !recordingSuspended, alternativePreparationAllowed?() != false,
            let decision = library.referenceDecision(meetingID: meetingID, speakerID: speakerID, personID: personID)
        else { return }
        let selectionID = decision.referenceSelectionID
        let token = UUID()
        let predecessors = Array(referenceTasks.values) + Array(retiringReferences.values)
        referenceTokens[speakerID] = token
        referenceTasks[speakerID] = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool {
                self.referenceTokens[speakerID] == token
                    && self.library.referenceDecision(meetingID: meetingID, speakerID: speakerID, personID: personID)?
                        .referenceSelectionID == selectionID
                    && self.library.hasManualIdentity(meetingID: meetingID, speakerID: speakerID, personID: personID)
            }
            do {
                for predecessor in predecessors { await predecessor.value }
                try Task.checkCancellation()
                let result = try await self.prepareReference(
                    meetingID: meetingID, speakerID: speakerID, personID: personID,
                    selectionID: selectionID, exampleID: exampleID, directory: directory)
                if let result, await self.referenceWriteReady?() != false {
                    try Task.checkCancellation()
                    if current() {
                        _ = self.library.finishReferenceSelection(
                            meetingID: meetingID, speakerID: speakerID, personID: personID,
                            result: result, expectedSelectionID: selectionID)
                    }
                }
            }
            catch is CancellationError {
                // Suspension and a newer assignment preserve pending work for the current identity.
            }
            catch {
                if !Task.isCancelled, await self.referenceWriteReady?() != false,
                    !Task.isCancelled, current(), !self.recordingSuspended,
                    self.alternativePreparationAllowed?() != false
                {
                    _ = self.library.finishReferenceSelection(
                        meetingID: meetingID, speakerID: speakerID, personID: personID,
                        result: .init(outcome: .failed), expectedSelectionID: selectionID)
                }
            }
            self.retiringReferences[token] = nil
            if self.referenceTokens[speakerID] == token {
                self.referenceTasks[speakerID] = nil
                self.referenceTokens[speakerID] = nil
            }
        }
    }

    func cancelReference(speakerID: UUID) {
        if let task = referenceTasks.removeValue(forKey: speakerID),
            let token = referenceTokens.removeValue(forKey: speakerID)
        {
            task.cancel()
            retiringReferences[token] = task
        }
    }

    func awaitReferenceSelections() async {
        for task in Array(referenceTasks.values) + Array(retiringReferences.values) { await task.value }
    }

    private func prepareReference(
        meetingID: UUID, speakerID: UUID, personID: UUID, selectionID: UUID?, exampleID: UUID?, directory: URL
    ) async throws -> VoiceReferenceSelectionResult? {
        func check() throws {
            try Task.checkCancellation()
            guard !recordingSuspended, alternativePreparationAllowed?() != false,
                library.hasManualIdentity(meetingID: meetingID, speakerID: speakerID, personID: personID),
                library.referenceDecision(meetingID: meetingID, speakerID: speakerID, personID: personID)?
                    .referenceSelectionID == selectionID
            else { throw CancellationError() }
        }
        try check()
        let retained = library.examples.filter { example in
            guard let origin = example.selectedReference else { return false }
            return origin.meetingID == meetingID && origin.speakerID == speakerID && origin.personID == personID
                && example.personID == personID && example.review == .confirmed
                && !example.excluded && !example.manuallyCleared
        }
        if !retained.isEmpty {
            let profiles = try await library.matchingPeople(from: people())
            try check()
            let active = Set(profiles.first { $0.id == personID }?.voiceSamples.map(\.speakerID) ?? [])
            if let existing = retained.first(where: { active.contains($0.id) }) {
                return .init(outcome: .sampleAvailable, sampleID: existing.id, audioRevision: existing.audioRevision)
            }
        }
        let snapshot: VoiceDiscoverySourceReader.Snapshot
        do { snapshot = try await inventoryReader.read(meetingID: meetingID, folder: directory) }
        catch {
            let exists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: directory.path)
            }.value
            if !exists { return .init(outcome: .audioUnavailable) }
            throw error
        }
        try check()
        // Legacy passage corrections retain their separate Undo scope and do not
        // enroll recording-wide reference evidence.
        if snapshot.meeting.speakers.first(where: { $0.id == speakerID })?.passageAssignmentOrigin != nil {
            return .init(outcome: .passageOnly)
        }
        guard !snapshot.meeting.audioFiles.isEmpty, !snapshot.revisions.isEmpty
        else { return .init(outcome: .audioUnavailable) }
        let input = VoiceDiscoveryInput(
            meetingID: meetingID, audioFiles: snapshot.meeting.audioFiles, audioRevisions: snapshot.revisions)
        guard
            let analysis = try await discoveryCache.read(input: input, configuration: .community, directory: directory)
        else { return .init(outcome: .scanNeeded) }
        try check()
        let current = library.examples.filter { example in
            guard example.meetingID == meetingID, let file = example.audioFile,
                let revision = snapshot.revisions[file], example.audioRevision == revision, let range = example.range
            else { return false }
            return example.id == exampleID || example.speakerID == speakerID
                || VoiceReferenceSelection.supportedRange(range: range, meeting: snapshot.meeting, speakerID: speakerID)
                    != nil
        }
        func priority(_ example: VoiceExample) -> Int {
            example.id == exampleID ? 0 : (example.speakerID == speakerID ? 1 : 2)
        }
        let originals = current.sorted {
            priority($0) == priority($1) ? $0.id.uuidString < $1.id.uuidString : priority($0) < priority($1)
        }
        // Current analysis resolves a completed attempt even if an older,
        // pre-conversion excerpt has no current usable equivalent.
        guard !originals.isEmpty else { return .init(outcome: .noSuitableSample) }
        var originalIndex = 0
        var attempted = library.examples.filter { $0.isReviewed && $0.selectedReference == nil }
        var audioAttempts = 0
        var rejection: VoiceReferenceSelection.Rejection?
        for _ in 0..<64 {
            try check()
            if audioAttempts >= 3 { break }
            guard originalIndex < originals.count else { break }
            let original = originals[originalIndex]
            // Select from all retained turns rather than approving whichever excerpt
            // happened to be displayed. The selector excludes detected overlap and
            // unresolved turns. Exclusive output still cannot prove perceptual clarity.
            let excluded = attempted
            let selection = await Task.detached(priority: .utility) {
                VoiceAlternativeSamples.select(
                    original: original, analysis: analysis, existing: excluded,
                    preferredTurn: original.id == exampleID ? original.attributionTurn : nil)
            }.value
            guard let selection, let rawRange = selection.range else {
                originalIndex += 1
                continue
            }
            // Unsupported windows are cheap metadata candidates. They do not use
            // the bounded budget for actual audio decoding and model work.
            let raw = VoiceExample(
                meetingID: meetingID, speakerID: speakerID, source: rawRange.source,
                audioFile: rawRange.audioFile, audioRevision: original.audioRevision,
                start: rawRange.start, end: rawRange.end, spans: rawRange.spans)
            attempted.append(raw)
            guard
                let range = VoiceReferenceSelection.supportedRange(
                    range: rawRange, meeting: snapshot.meeting, speakerID: speakerID),
                let revision = snapshot.revisions[range.audioFile], revision == original.audioRevision
            else { continue }
            var candidate = VoiceExample(
                meetingID: meetingID, speakerID: speakerID, source: range.source, audioFile: range.audioFile,
                audioRevision: revision, start: range.start, end: range.end,
                groupID: speakerID, origin: .discovery, spans: range.spans,
                detectedSpeakerID: selection.detectedSpeakerID,
                detectedSpeakerResultID: selection.detectedSpeakerResultID,
                detectedSpeakerConfiguration: .community, detectedSpeakerSpans: selection.detectedSpeakerSpans)
            let audioIdentity = Self.discoveryIdentity(
                meetingID: meetingID, range: range, revision: revision, model: analysis.modelRevision)
            candidate.id = VoiceProjectionOrigin.identity(exampleID: speakerID, segmentID: audioIdentity)
            if let existing = library.examples.first(where: { $0.id == candidate.id }) {
                if existing.selectedReference == nil || (existing.personID == personID && existing.review == .confirmed)
                {
                    attempted.append(candidate)
                    continue
                }
            }
            attempted.append(candidate)
            guard
                VoiceReferenceSelection.isSupported(
                    range: range, meeting: snapshot.meeting, speakerID: speakerID)
            else { continue }
            audioAttempts += 1
            let readSamples = referenceReadSamples
            let quality = try await Task.detached(priority: .utility) {
                let samples = try readSamples(directory.appendingPathComponent(range.audioFile), range)
                try Task.checkCancellation()
                return VoiceSampleQuality.assess(
                    range: range, audioRevision: revision,
                    scanConfiguration: VoiceDiscoveryConfiguration.community.pipeline, samples: samples)
            }.value
            try check()
            guard let quality, quality.issue == nil else { continue }
            candidate.sampleQuality = quality
            let worker = referenceExtractor ?? LocalVoiceExampleExtractor()
            let embedding: TypedVoiceEmbedding
            do {
                embedding = try await worker.extract(
                    example: candidate, directory: directory, type: CommunityVoiceEmbeddingExtractor.embeddingType)
            }
            catch {
                await worker.finish()
                throw error
            }
            await worker.finish()
            try check()
            guard embedding.isValid, embedding.type == CommunityVoiceEmbeddingExtractor.embeddingType else {
                return .init(outcome: .failed)
            }
            let profiles = try await library.matchingPeople(from: people())
            try check()
            let referenceIDs = Set(profiles.first { $0.id == personID }?.voiceSamples.map(\.speakerID) ?? [])
            if let reason = VoiceReferenceSelection.rejection(
                embedding: embedding, personID: personID, profiles: profiles, candidate: candidate,
                referenceExamples: library.reviewEvidence(for: referenceIDs))
            {
                if rejection != .alreadyRepresented { rejection = reason }
                continue
            }
            guard await referenceWriteReady?() != false else { return nil }
            try check()
            let latest = try await inventoryReader.read(meetingID: meetingID, folder: directory)
            try check()
            guard latest.revisions == snapshot.revisions,
                VoiceReferenceSelection.isSupported(range: range, meeting: latest.meeting, speakerID: speakerID)
            else { return nil }
            // Re-read suspension/save state after inventory I/O, then publish without an await.
            guard await referenceWriteReady?() != false else { return nil }
            try check()
            candidate.embeddings = [embedding]
            guard library.acceptSelectedReference(candidate, personID: personID, speakerID: speakerID) else {
                return .init(outcome: .failed)
            }
            return .init(outcome: .sampleAdded, sampleID: candidate.id, audioRevision: candidate.audioRevision)
        }
        return .init(
            outcome: rejection == .alreadyRepresented
                ? .alreadyRepresented
                : (rejection == .conflictingEvidence ? .conflictingEvidence : .noSuitableSample))
    }

    /// Prepares independent evidence without replacing the original excerpt or its decision.
    func tryAnotherSample(exampleID: UUID, directory: URL) async throws -> VoiceAlternativeSampleResult {
        guard !recordingSuspended, alternativePreparationAllowed?() != false else {
            throw ServiceError("Wait for recording to finish before preparing another sample.")
        }
        if let previous = alternativeRequest, let pending = alternativeTask {
            pending.cancel()
            retiringAlternatives[previous] = pending
        }
        let request = UUID()
        alternativeRequest = request
        let task = Task {
            try await prepareAlternativeSample(exampleID: exampleID, directory: directory, request: request)
        }
        alternativeTask = task
        defer {
            retiringAlternatives.removeValue(forKey: request)
            if alternativeRequest == request {
                alternativeRequest = nil
                alternativeTask = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func checkAlternativeRequest(_ request: UUID) throws {
        try Task.checkCancellation()
        guard alternativeRequest == request, !recordingSuspended, alternativePreparationAllowed?() != false else {
            throw CancellationError()
        }
    }

    private func prepareAlternativeSample(exampleID: UUID, directory: URL, request: UUID) async throws
        -> VoiceAlternativeSampleResult
    {
        try checkAlternativeRequest(request)
        guard await library.awaitReady() else {
            throw ServiceError(library.errorMessage ?? "Couldn’t open the voice library.")
        }
        try checkAlternativeRequest(request)
        guard let original = library.examples.first(where: { $0.id == exampleID }), original.range != nil else {
            throw ServiceError("This sample has no recording excerpt.")
        }
        let snapshot = try await inventoryReader.read(meetingID: original.meetingID, folder: directory)
        try checkAlternativeRequest(request)
        let input = VoiceDiscoveryInput(
            meetingID: original.meetingID, audioFiles: snapshot.meeting.audioFiles,
            audioRevisions: snapshot.revisions)
        let configuration = VoiceDiscoveryConfiguration.community
        let retainedAnalysis = try await discoveryCache.read(
            input: input, configuration: configuration, directory: directory)
        try checkAlternativeRequest(request)
        guard let analysis = retainedAnalysis else { return .analysisUnavailable }
        guard let current = library.examples.first(where: { $0.id == exampleID }),
            current.hasSameReviewEvidence(as: original), library.audioIsCurrent(current)
        else { throw ServiceError("The sample changed. Select it again to try another excerpt.") }
        let existing = library.examples.filter { $0.meetingID == original.meetingID }
        let selectionTask = Task.detached(priority: .utility) {
            VoiceAlternativeSamples.select(original: original, analysis: analysis, existing: existing)
        }
        let selection = await withTaskCancellationHandler {
            await selectionTask.value
        } onCancel: {
            selectionTask.cancel()
        }
        try checkAlternativeRequest(request)
        guard let selection else { return .speakerUnresolved }
        guard let range = selection.range else { return .exhausted }
        guard let revision = snapshot.revisions[range.audioFile], revision == original.audioRevision else {
            throw ServiceError("The recording changed. Scan it again before choosing another sample.")
        }
        let identity = Self.discoveryIdentity(
            meetingID: original.meetingID, range: range, revision: revision, model: analysis.modelRevision)
        var candidate = VoiceExample(
            id: identity, meetingID: original.meetingID, speakerID: identity, source: range.source,
            audioFile: range.audioFile, audioRevision: revision, start: range.start, end: range.end,
            groupID: identity, origin: .discovery, spans: range.spans)
        candidate.detectedSpeakerID = selection.detectedSpeakerID
        candidate.detectedSpeakerResultID = selection.detectedSpeakerResultID
        candidate.detectedSpeakerConfiguration = configuration
        candidate.detectedSpeakerSpans = selection.detectedSpeakerSpans
        let worker = extractor ?? LocalVoiceExampleExtractor()
        let representation: TypedVoiceEmbedding
        do {
            representation = try await worker.extract(
                example: candidate, directory: directory, type: CommunityVoiceEmbeddingExtractor.embeddingType)
        }
        catch {
            await worker.finish()
            throw error
        }
        await worker.finish()
        try checkAlternativeRequest(request)
        let qualityTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard
                let samples = try? LocalVoiceExampleExtractor.readSamples(
                    url: directory.appendingPathComponent(range.audioFile), spans: range.supportSpans)
            else { return Optional<VoiceSampleQuality>.none }
            try Task.checkCancellation()
            return VoiceSampleQuality.assess(
                range: range, audioRevision: revision, scanConfiguration: configuration.pipeline, samples: samples)
        }
        candidate.sampleQuality = try await withTaskCancellationHandler {
            try await qualityTask.value
        } onCancel: {
            qualityTask.cancel()
        }
        try checkAlternativeRequest(request)
        guard representation.type == CommunityVoiceEmbeddingExtractor.embeddingType, representation.isValid else {
            throw ServiceError("The provider returned an incompatible voice representation.")
        }
        guard let latest = library.examples.first(where: { $0.id == exampleID }),
            latest.hasSameReviewEvidence(as: original), library.audioIsCurrent(latest),
            library.audioIsCurrent(candidate)
        else { throw ServiceError("The sample changed during preparation. Try again.") }
        // A concurrent scan or another review may have published this evidence.
        guard
            !library.examples.contains(where: {
                $0.meetingID == original.meetingID && $0.audioRevision == revision
                    && $0.range.map { $0.overlaps(range) } == true
            })
        else { throw ServiceError("Another sample was added during preparation. Try again.") }
        candidate.embeddings = [representation]
        guard library.upsert([candidate]) else {
            throw ServiceError(library.errorMessage ?? "Couldn’t save the voice sample.")
        }
        return .prepared(candidate)
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
        let references = Array(referenceTasks.values) + Array(retiringReferences.values)
        retiringReferences.removeAll()
        referenceTasks.removeAll()
        referenceTokens.removeAll()
        for task in references { task.cancel() }
        alternativeRequest = nil
        let pendingAlternatives = Array(retiringAlternatives.values) + (alternativeTask.map { [$0] } ?? [])
        alternativeTask = nil
        retiringAlternatives = [:]
        for task in pendingAlternatives { task.cancel() }
        recordingPausedJobs = []
        let pending = Array(tasks.values) + Array(retiringRuns.values)
        for id in Array(tasks.keys) { pause(jobID: id) }
        for task in pending { await task.value }
        for task in references { await task.value }
        for task in pendingAlternatives { _ = try? await task.value }
    }

    func suspendForRecording() {
        recordingSuspended = true
        for task in referenceTasks.values { task.cancel() }
        if let request = alternativeRequest, let pending = alternativeTask {
            pending.cancel()
            retiringAlternatives[request] = pending
        }
        alternativeRequest = nil
        alternativeTask = nil
        let running = library.jobs.filter { $0.state == .running && tasks[$0.id] != nil }.map(\.id)
        recordingPausedJobs = running
        for id in running { pause(jobID: id, reason: "Paused for recording") }
    }

    func resumePendingReferences(directory: (UUID) -> URL) {
        guard !recordingSuspended, alternativePreparationAllowed?() != false else { return }
        for decision in library.decisions where decision.referenceSelectionPending == true {
            guard let personID = decision.personID else { continue }
            selectReference(
                meetingID: decision.meetingID, speakerID: decision.speakerID,
                personID: personID, exampleID: nil, directory: directory(decision.meetingID))
        }
    }

    func resumeAfterRecording(directory: @escaping (UUID) -> URL) {
        recordingSuspended = false
        resumePendingReferences(directory: directory)
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
        guard canResume(job) else { return }
        guard
            update(
                jobID,
                {
                    $0.state = .running
                    $0.failures.removeValue(forKey: "configuration")
                    $0.progressStartedAt = Date()
                    $0.estimatedRemainingSeconds = nil
                })
        else { return }
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
            guard !Task.isCancelled, runTokens[jobID] == token,
                let current = library.jobs.first(where: { $0.id == jobID })
            else { return }
            guard canResume(current) else {
                let reason = errorMessage ?? "The provider changed. Review General settings before resuming."
                update(jobID) {
                    $0.state = .paused
                    $0.failures["configuration"] = reason
                }
                return
            }
            await run(jobID: jobID, directory: directory)
        }
    }

    private func canResume(_ job: VoicePreparationJob) -> Bool {
        if let currentProvider {
            guard let provider = currentProvider() else {
                errorMessage = "Choose a Speaker Diarization provider in General settings before resuming."
                return false
            }
            if let reason = Self.resumeUnavailableReason(for: job, provider: provider) {
                errorMessage = reason
                return false
            }
        }
        else if extractor == nil, let reason = Self.resumeUnavailableReason(for: job) {
            errorMessage = reason
            return false
        }
        errorMessage = nil
        return true
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
        guard
            update(
                jobID,
                {
                    if $0.discover && $0.discoveryConfiguration == nil {
                        // Earlier receipts lack full model/configuration identity.
                        // Revalidate from zero rather than claiming their work is current.
                        $0.completedRecordingIDs = []
                        $0.fullyAnalyzedRecordingIDs = []
                    }
                    $0.progressPhase = "Analyzing recordings"
                    $0.progressStartedAt = Date()
                    $0.estimatedRemainingSeconds = nil
                })
        else { return }
        await discoverRecordings(jobID: jobID, directory: directory, discoverer: discoverer)
        guard let job = library.jobs.first(where: { $0.id == jobID }), job.state == .running else { return }
        let performanceKey = TaskPerformanceKey(
            operation: "voiceExampleEmbedding", provider: job.providerID.uuidString,
            model: job.type.modelID, configuration: job.type.revision + ":" + job.type.compatibilityVersion)
        guard
            update(
                jobID,
                {
                    $0.progressPhase = "Preparing voice examples"
                    $0.progressStartedAt = Date()
                })
        else { return }
        defer { library.releaseRepresentations() }
        var completed = Set(job.completedExampleIDs)
        var pendingCompletions: [UUID] = []
        var pendingFailures: [String: String] = [:]
        var completionSources: [UUID: VoiceExample] = [:]
        var checkpointStarted = SuspendingClock.now
        var metadataRevision = library.reviewMetadataRevision
        var representationRevision = library.representationsRevision
        var metadata = Dictionary(uniqueKeysWithValues: library.examples.map { ($0.id, $0) })
        var aliases = Dictionary(grouping: library.examples, by: VoiceExactReviewDecisions.Key.init)
        var representationOwners: [VoiceExactReviewDecisions.Key: UUID] = [:]
        var reusedVectors: [VoiceExactReviewDecisions.Key: TypedVoiceEmbedding] = [:]

        func markCompleted(_ id: UUID) {
            if completed.insert(id).inserted {
                pendingCompletions.append(id)
                completionSources[id] = metadata[id]
            }
            pendingFailures.removeValue(forKey: id.uuidString)
        }
        func checkpoint() -> Bool {
            guard !pendingCompletions.isEmpty || !pendingFailures.isEmpty else { return true }
            guard !Task.isCancelled, library.jobs.first(where: { $0.id == jobID })?.state == .running else {
                return false
            }
            refreshMetadata()
            var checkedAudio: [String: Bool] = [:]
            let currentCompletions = pendingCompletions.filter { id in
                guard let original = completionSources[id], let current = metadata[id], !current.excluded else {
                    return true
                }
                let sameSource = original.range == current.range && original.audioRevision == current.audioRevision
                let audioKey = "\(current.meetingID)|\(current.audioFile ?? "")|\(current.audioRevision ?? "")"
                let audioCurrent: Bool
                if current.audioRevision == nil {
                    audioCurrent = true
                }
                else if let checked = checkedAudio[audioKey] {
                    audioCurrent = checked
                }
                else {
                    audioCurrent = library.audioIsCurrent(current)
                    checkedAudio[audioKey] = audioCurrent
                }
                guard sameSource, audioCurrent else {
                    completed.remove(id)
                    pendingFailures[id.uuidString] =
                        "The source audio changed during preparation. Review a new example."
                    return false
                }
                return true
            }
            guard complete(currentCompletions, failures: pendingFailures, jobID: jobID) else { return false }
            pendingCompletions.removeAll(keepingCapacity: true)
            pendingFailures.removeAll(keepingCapacity: true)
            completionSources.removeAll(keepingCapacity: true)
            reusedVectors.removeAll(keepingCapacity: true)
            library.releaseRepresentations()
            checkpointStarted = SuspendingClock.now
            return true
        }
        func refreshMetadata() {
            guard
                metadataRevision != library.reviewMetadataRevision
                    || representationRevision != library.representationsRevision
            else { return }
            metadata = Dictionary(uniqueKeysWithValues: library.examples.map { ($0.id, $0) })
            aliases = Dictionary(grouping: library.examples, by: VoiceExactReviewDecisions.Key.init)
            metadataRevision = library.reviewMetadataRevision
            representationRevision = library.representationsRevision
            representationOwners.removeAll(keepingCapacity: true)
            reusedVectors.removeAll(keepingCapacity: true)
        }
        func remember(_ value: TypedVoiceEmbedding, example: VoiceExample) {
            guard let key = VoiceExactReviewDecisions.Key(example) else { return }
            representationOwners[key] = example.id
            reusedVectors[key] = value
        }
        func compatibleAlias(for example: VoiceExample) -> TypedVoiceEmbedding? {
            guard let key = VoiceExactReviewDecisions.Key(example) else { return nil }
            if let value = reusedVectors[key] { return value }
            let known = representationOwners[key]
            let ids = (known.map { [$0] } ?? []) + (aliases[key] ?? []).map(\.id).filter { $0 != known }
            for id in ids where id != example.id {
                guard let current = metadata[id], VoiceExactReviewDecisions.Key(current) == key,
                    let alias = library.hydratedExample(id: id),
                    let value = alias.voiceEmbeddings.first(where: { $0.type == job.type && $0.isValid })
                else { continue }
                remember(value, example: alias)
                return value
            }
            return nil
        }

        let pending = Set(job.exampleIDs).subtracting(completed)
        let remainingDurations = Dictionary(
            uniqueKeysWithValues: library.examples.compactMap { example -> (UUID, Double)? in
                guard pending.contains(example.id), !example.excluded, let duration = example.range?.speechDuration
                else { return nil }
                return (example.id, duration)
            })
        var remainingAudio = remainingDurations.values.reduce(0, +)
        var measuredAudio = 0.0
        var measuredSeconds = 0.0
        for (position, exampleID) in job.exampleIDs.enumerated() {
            if position > 0 && (position.isMultiple(of: 64) || AudioTaskProgress.elapsed(since: checkpointStarted) >= 1)
            {
                guard checkpoint() else { return }
                await Task.yield()
            }
            guard !Task.isCancelled,
                library.jobs.first(where: { $0.id == jobID })?.state == .running
            else { return }
            if completed.contains(exampleID) { continue }
            defer { remainingAudio = max(0, remainingAudio - (remainingDurations[exampleID] ?? 0)) }
            refreshMetadata()
            guard let currentMetadata = metadata[exampleID], !currentMetadata.excluded else {
                markCompleted(exampleID)
                continue
            }
            // A current scan's failed PCM assessment is already an analysis result.
            // Retrying the same unusable excerpt cannot produce useful evidence.
            if job.discover, let configuration = job.discoveryConfiguration,
                currentMetadata.detectedSpeakerConfiguration == configuration,
                let quality = currentMetadata.currentSampleQuality,
                quality.scanConfiguration == configuration.pipeline, quality.issue != nil
            {
                if library.audioIsCurrent(currentMetadata) {
                    markCompleted(exampleID)
                }
                else {
                    pendingFailures[exampleID.uuidString] = "Audio is unavailable for this model’s preparation."
                }
                continue
            }
            guard let example = library.hydratedExample(id: exampleID) else {
                pendingFailures[exampleID.uuidString] = "Couldn’t read saved voice representations."
                continue
            }
            if let value = example.voiceEmbeddings.first(where: { $0.type == job.type && $0.isValid }),
                example.audioRevision == nil || library.audioIsCurrent(currentMetadata)
            {
                remember(value, example: example)
                markCompleted(exampleID)
                continue
            }
            guard library.audioIsCurrent(currentMetadata) else {
                pendingFailures[exampleID.uuidString] = "Audio is unavailable for this model’s preparation."
                continue
            }
            if let value = compatibleAlias(for: example) {
                guard library.addRepresentation(exampleID: exampleID, embedding: value) else { return }
                representationRevision = library.representationsRevision
                remember(value, example: example)
                markCompleted(exampleID)
                continue
            }
            do {
                updateExampleEstimate(jobID: jobID, key: performanceKey, remainingAudio: remainingAudio)
                let representation = try await extractor.extract(
                    example: example, directory: directory(example.meetingID), type: job.type)
                try Task.checkCancellation()
                guard library.jobs.first(where: { $0.id == jobID })?.state == .running else { return }
                refreshMetadata()
                guard representation.type == job.type, representation.isValid else {
                    throw ServiceError("The provider returned an incompatible voice representation.")
                }
                // Exclusion and audio changes during extraction invalidate its snapshot.
                guard let current = library.examples.first(where: { $0.id == exampleID }), !current.excluded else {
                    markCompleted(exampleID)
                    continue
                }
                guard current.audioFile == example.audioFile, current.start == example.start,
                    current.spans == example.spans,
                    current.end == example.end, current.audioRevision == example.audioRevision,
                    library.audioIsCurrent(current)
                else { throw ServiceError("The source audio changed during preparation. Review a new example.") }
                guard library.addRepresentation(exampleID: exampleID, embedding: representation) else { return }
                representationRevision = library.representationsRevision
                remember(representation, example: current)
                markCompleted(exampleID)
                if let seconds = await extractor.processingDuration(), let duration = example.range?.speechDuration {
                    try Task.checkCancellation()
                    guard library.jobs.first(where: { $0.id == jobID })?.state == .running else { return }
                    measuredAudio += duration
                    measuredSeconds += seconds
                    // Short examples can finish below the cache's minimum sample interval.
                    if measuredSeconds >= 0.25 {
                        performanceCache?.record(
                            key: performanceKey, completedUnits: measuredAudio,
                            elapsedSeconds: measuredSeconds)
                        measuredAudio = 0
                        measuredSeconds = 0
                    }
                }
            }
            catch is CancellationError { return }
            catch { pendingFailures[exampleID.uuidString] = error.localizedDescription }
        }
        guard checkpoint() else { return }
        guard !Task.isCancelled else { return }
        guard
            update(
                jobID,
                {
                    $0.progressPhase = "Comparing voice examples"
                    $0.progressStartedAt = Date()
                    $0.estimatedRemainingSeconds = nil
                })
        else { return }
        await library.suggestReviewedPeople(from: people(), policy: currentProvider?()?.voiceMatchingPolicy ?? .default)
        guard !Task.isCancelled else { return }
        update(jobID) { $0.state = $0.failures.isEmpty ? .completed : .failed }
        resumePendingReferences(directory: directory)
    }

    private func updateExampleEstimate(jobID: UUID, key: TaskPerformanceKey, remainingAudio: Double) {
        guard !Task.isCancelled else { return }
        let estimate = performanceCache?.estimate(key: key, remainingUnits: remainingAudio)
        library.setJobTimeEstimate(estimate, jobID: jobID)
    }

    private func discoverRecordings(jobID: UUID, directory: (UUID) -> URL, discoverer: any VoiceRecordingDiscovering)
        async
    {
        guard let job = library.jobs.first(where: { $0.id == jobID }), job.discover else { return }
        let configuration = await discoverer.configuration()
        guard !Task.isCancelled, library.jobs.first(where: { $0.id == jobID })?.state == .running else { return }
        if let previous = job.discoveryConfiguration, previous != configuration {
            update(jobID) {
                $0.failures["configuration"] = "The analysis model changed. Start a new scan."
                $0.state = .failed
            }
            return
        }
        guard update(jobID, { $0.discoveryConfiguration = configuration }) else { return }
        for var input in job.discoveryInputs {
            await Task.yield()
            guard !Task.isCancelled, library.jobs.first(where: { $0.id == jobID })?.state == .running else { return }
            let failureKey = "recording-" + input.meetingID.uuidString
            do {
                let root = directory(input.meetingID).standardizedFileURL.resolvingSymlinksInPath()
                let saved = try await inventoryReader.read(meetingID: input.meetingID, folder: root)
                try Task.checkCancellation()
                guard library.jobs.first(where: { $0.id == jobID })?.state == .running else { return }
                guard saved.meeting.audioFiles == input.audioFiles else {
                    throw ServiceError("The recording sources changed. Start a new scan.")
                }
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
                    else { throw ServiceError("The source audio changed or is unavailable. Start a new scan.") }
                    return url
                }
                if job.discoveryConfiguration == configuration,
                    job.completedRecordingIDs.contains(input.meetingID)
                {
                    // Only current-config checkpoints can bypass replay. Source
                    // revisions were checked above, even for completed inputs.
                    continue
                }
                guard library.ingest(meeting: saved.meeting, directory: root) else { return }
                let existing = library.examples.filter { $0.meetingID == input.meetingID && library.audioIsCurrent($0) }
                // Saved labels can cover a few excerpts without analyzing all speech.
                // Only a complete, revision-matched model result skips recording analysis.
                let cached = try await discoveryCache.read(input: input, configuration: configuration, directory: root)
                try Task.checkCancellation()
                guard library.jobs.first(where: { $0.id == jobID })?.state == .running else { return }
                let result: LocalDiarizationResult
                if let cached {
                    result = try await VoiceSampleQuality.refresh(
                        result: cached, input: input, configuration: configuration, directory: root)
                }
                else {
                    result = try await discoverer.discover(files: files)
                }
                try Task.checkCancellation()
                let returnedEmbeddings =
                    result.speakers.compactMap(\.voiceEmbedding)
                    + (result.turnSamples ?? []).compactMap(\.voiceEmbedding)
                guard cached != nil || returnedEmbeddings.allSatisfy({ $0.type == job.type })
                else {
                    throw ServiceError("The provider returned an incompatible voice representation.")
                }
                guard
                    zip(input.audioFiles, files).allSatisfy({
                        input.audioRevisions[$0.0] == VoiceLibraryStore.revision(url: $0.1)
                    })
                else { throw ServiceError("The source audio changed during analysis. Start a new scan.") }
                let candidates: [VoiceExample] =
                    result.turnSamples != nil
                    ? Self.turnExamples(result: result, meetingID: input.meetingID, configuration: configuration)
                    : result.speakers.compactMap { speaker in
                        guard let range = speaker.voiceSampleRange, range.isValid,
                            input.audioFiles.contains(range.audioFile),
                            let revision = input.audioRevisions[range.audioFile]
                        else { return nil }
                        let identity = Self.discoveryIdentity(
                            meetingID: input.meetingID, range: range, revision: revision, model: result.modelRevision)
                        var candidate = VoiceExample(
                            id: identity, meetingID: input.meetingID, speakerID: identity, source: range.source,
                            audioFile: range.audioFile, audioRevision: revision, start: range.start, end: range.end,
                            embeddings: speaker.voiceEmbedding.map { $0.isValid ? [$0] : [] } ?? [],
                            groupID: identity, origin: .discovery, spans: range.spans,
                            sampleQuality: result.sampleQualities?[
                                VoiceSampleQuality.speakerKey(track: speaker.track, label: speaker.label)])
                        candidate.detectedSpeakerID = VoiceDetectedSpeakerScope.identity(
                            speaker: speaker, analysis: result)
                        candidate.detectedSpeakerResultID = result.id
                        candidate.detectedSpeakerConfiguration = configuration
                        candidate.detectedSpeakerSpans = VoiceDetectedSpeakerScope.spans(
                            speaker: speaker, analysis: result)
                        return candidate
                    }
                guard candidates.allSatisfy({ input.audioRevisions[$0.audioFile ?? ""] == $0.audioRevision }) else {
                    throw ServiceError("The source audio changed during turn extraction. Start a new scan.")
                }
                // Persist refreshed PCM assessments without rerunning diarization.
                try await discoveryCache.save(result, input: input, configuration: configuration, directory: root)
                try Task.checkCancellation()
                guard library.jobs.first(where: { $0.id == jobID })?.state == .running else { return }
                guard
                    zip(input.audioFiles, files).allSatisfy({
                        input.audioRevisions[$0.0] == VoiceLibraryStore.revision(url: $0.1)
                    })
                else { throw ServiceError("The source audio changed during analysis. Start a new scan.") }
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
                guard
                    update(
                        jobID,
                        {
                            $0.failures[failureKey] = error.localizedDescription
                            $0.completedRecordingIDs.removeAll { $0 == input.meetingID }
                            $0.fullyAnalyzedRecordingIDs?.removeAll { $0 == input.meetingID }
                        })
                else { return }
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
            var known = Set($0.exampleIDs)
            for example in examples where known.insert(example.id).inserted { $0.exampleIDs.append(example.id) }
        }
    }

    /// Exact turn identities are stable across retries and separate from cluster-wide manual decisions.
    nonisolated static func turnExamples(
        result: LocalDiarizationResult, meetingID: UUID,
        configuration: VoiceDiscoveryConfiguration = .community
    ) -> [VoiceExample] {
        (result.turnSamples ?? []).compactMap { turn in
            guard let range = turn.sampleRange, range.isValid,
                let revision = turn.audioRevision, !revision.isEmpty,
                turn.start.isFinite, turn.end.isFinite, turn.start >= 0, turn.end > turn.start,
                range.start + 1.0 / 16000 >= turn.start, range.end <= turn.end + 1.0 / 16000,
                range.speechDuration >= 2, range.speechDuration <= 10 + 1.0 / 16000,
                turn.sampleQuality?.issue == nil,
                result.ranges.contains(where: {
                    $0.track == turn.track && $0.label == turn.label && $0.start == turn.start
                        && $0.end == turn.end && $0.associationUncertain != true
                }),
                !result.ranges.contains(where: {
                    $0.track == turn.track && $0.label != turn.label && $0.start < turn.end && turn.start < $0.end
                }),
                let speaker = result.speakers.first(where: { $0.track == turn.track && $0.label == turn.label })
            else { return nil }
            let identity = discoveryIdentity(
                meetingID: meetingID, range: range, revision: revision,
                model: result.modelRevision + "|independent-turn-v2|\(turn.start):\(turn.end)")
            let support = SpeakerEvidenceSpan(start: turn.start, end: turn.end)
            return VoiceExample(
                id: identity, meetingID: meetingID, speakerID: speaker.id, source: range.source,
                audioFile: range.audioFile, audioRevision: revision, start: range.start, end: range.end,
                embeddings: turn.voiceEmbedding.map { $0.isValid ? [$0] : [] } ?? [],
                groupID: identity, origin: .discovery, spans: range.spans,
                detectedSpeakerID: VoiceDetectedSpeakerScope.identity(speaker: speaker, analysis: result),
                detectedSpeakerResultID: result.id, detectedSpeakerConfiguration: configuration,
                detectedSpeakerSpans: [support], attributionTurn: support, sampleQuality: turn.sampleQuality)
        }
    }

    /// Replaying a completed model result after a crash cannot duplicate evidence.
    nonisolated static func discoveryIdentity(meetingID: UUID, range: VoiceSampleRange, revision: String, model: String)
        -> UUID
    {
        let support = range.spans.map { "|" + $0.map { "\($0.start):\($0.end)" }.joined(separator: ",") } ?? ""
        let key = "\(meetingID)|\(range.audioFile)|\(range.start)|\(range.end)|\(revision)|\(model)\(support)"
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
    private func complete(_ exampleIDs: [UUID], failures: [String: String], jobID: UUID) -> Bool {
        update(jobID) {
            var known = Set($0.completedExampleIDs)
            for id in exampleIDs {
                if known.insert(id).inserted { $0.completedExampleIDs.append(id) }
                $0.failures.removeValue(forKey: id.uuidString)
            }
            $0.failures.merge(failures) { _, latest in latest }
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

/// A manual identity permits the first supported reference. Existing compatible
/// evidence adds an inconsistency guard and avoids filling profiles with copies.
enum VoiceReferenceSelection {
    /// Retained scan scope must agree with the current transcript identity.
    /// A later transcription or an explicit passage correction can invalidate
    /// otherwise usable cached analysis without changing the audio revision.
    static func supportedRange(range: VoiceSampleRange, meeting: Meeting, speakerID: UUID) -> VoiceSampleRange? {
        guard range.isValid else { return nil }
        let speakers = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0) })
        func sourceMatches(_ row: TranscriptSegment) -> Bool {
            if let source = row.source { return source.rawValue == range.source }
            return row.speakerID.flatMap { speakers[$0] }.map {
                $0.track == range.source || ($0.track == "system_mix" && range.source == "system")
                    || ($0.track == "mic" && range.source == "microphone")
            } ?? false
        }
        func supports(_ row: TranscriptSegment) -> Bool {
            guard row.associationUncertain != true, let id = row.speakerID else { return false }
            if id == speakerID { return true }
            guard let speaker = speakers[id], speaker.passageAssignmentOrigin == nil else { return false }
            return speaker.voiceReviewOrigin?.speakerID == speakerID
        }
        let rows = meeting.transcript.filter {
            sourceMatches($0) && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }
        let blocked = rows.filter { !supports($0) }
        var pieces: [SpeakerEvidenceSpan] = []
        for support in range.supportSpans {
            for row in rows where supports(row) {
                var fragments = [
                    SpeakerEvidenceSpan(start: max(support.start, row.start), end: min(support.end, row.end))
                ].filter(\.isValid)
                for other in blocked {
                    fragments = fragments.flatMap { fragment in
                        if other.start >= fragment.end || other.end <= fragment.start { return [fragment] }
                        return [
                            SpeakerEvidenceSpan(start: fragment.start, end: min(fragment.end, other.start)),
                            SpeakerEvidenceSpan(start: max(fragment.start, other.end), end: fragment.end),
                        ].filter(\.isValid)
                    }
                }
                pieces += fragments
            }
        }
        pieces.sort { $0.start < $1.start }
        var merged: [SpeakerEvidenceSpan] = []
        for piece in pieces {
            let quantized = SpeakerEvidenceSpan(
                start: (piece.start * 16000).rounded(.up) / 16000,
                end: (piece.end * 16000).rounded(.down) / 16000)
            guard quantized.isValid else { continue }
            if let last = merged.last, quantized.start <= last.end {
                merged[merged.count - 1].end = max(last.end, quantized.end)
            }
            else {
                merged.append(quantized)
            }
        }
        if merged.count > 8 {
            merged = Array(merged.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(8)).sorted {
                $0.start < $1.start
            }
        }
        guard let first = merged.first, let last = merged.last else { return nil }
        let result = VoiceSampleRange(
            audioFile: range.audioFile, source: range.source, start: first.start, end: last.end,
            spans: merged.count == 1 ? nil : merged)
        return result.speechDuration >= 2 && result.speechDuration <= 10 + 1e-6 ? result : nil
    }

    static func isSupported(range: VoiceSampleRange, meeting: Meeting, speakerID: UUID) -> Bool {
        let speakers = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0) })
        func sameSource(_ row: TranscriptSegment) -> Bool {
            if let source = row.source { return source.rawValue == range.source }
            return row.speakerID.flatMap { speakers[$0] }.map {
                $0.track == range.source || ($0.track == "system_mix" && range.source == "system")
                    || ($0.track == "mic" && range.source == "microphone")
            } ?? false
        }
        func supports(_ row: TranscriptSegment) -> Bool {
            guard row.associationUncertain != true, let id = row.speakerID else { return false }
            if id == speakerID { return true }
            guard let speaker = speakers[id], speaker.passageAssignmentOrigin == nil else { return false }
            return speaker.voiceReviewOrigin?.speakerID == speakerID
        }
        let rows = meeting.transcript.filter { sameSource($0) && $0.end > $0.start }
        for span in range.supportSpans {
            let overlapping = rows.filter { $0.start < span.end && $0.end > span.start }
            guard !overlapping.isEmpty, overlapping.allSatisfy(supports) else { return false }
            var covered = span.start
            for row in overlapping.sorted(by: { $0.start < $1.start }) {
                guard row.start <= covered + 1.0 / 16000 else { return false }
                covered = max(covered, row.end)
            }
            guard covered + 1.0 / 16000 >= span.end else { return false }
        }
        return true
    }

    enum Rejection { case alreadyRepresented, conflictingEvidence, insufficientEvidence }

    static func permits(embedding: TypedVoiceEmbedding, personID: UUID, profiles: [Person]) -> Bool {
        rejection(embedding: embedding, personID: personID, profiles: profiles) == nil
    }

    static func rejection(
        embedding: TypedVoiceEmbedding, personID: UUID, profiles: [Person], candidate: VoiceExample? = nil,
        referenceExamples: [VoiceExample] = []
    ) -> Rejection? {
        guard embedding.isValid else { return .conflictingEvidence }
        func scores(_ person: Person) -> [Double] {
            person.voiceSamples.compactMap { sample in
                let reference = sample.resolvedVoiceEmbedding
                guard reference.type == embedding.type, reference.isValid else { return nil }
                return SpeakerRecognition.similarity(reference.values, embedding.values)
            }
        }
        let own = profiles.first(where: { $0.id == personID }).map(scores) ?? []
        if let best = own.max() {
            guard best >= VoiceMatchingPolicy.default.suggestionThreshold else { return .conflictingEvidence }
            // Profile selection already bounds representations. A practically
            // identical voice vector adds no useful diversity to that profile.
            if best >= 0.97 { return .alreadyRepresented }
        }
        let rival = profiles.filter { $0.id != personID }.flatMap(scores).max()
        if let rival, rival >= VoiceMatchingPolicy.default.automaticThreshold,
            rival > (own.max() ?? -1)
        {
            return .conflictingEvidence
        }
        guard own.count >= VoiceProfileSelection.maximumReferencesPerModel else { return nil }
        let metadata = Dictionary(referenceExamples.map { ($0.id, $0) }, uniquingKeysWith: { _, value in value })
        func evidence(_ example: VoiceExample, embedding: TypedVoiceEmbedding) -> SpeakerEvidenceSample? {
            guard let range = example.range else { return nil }
            return .init(
                id: example.id.uuidString, source: example.source, localSpeakerID: example.groupID.uuidString,
                start: range.start, end: range.end, embedding: embedding, spans: example.spans)
        }
        let existing =
            profiles.first { $0.id == personID }?.voiceSamples.compactMap { sample -> SpeakerEvidenceSample? in
                let value = sample.resolvedVoiceEmbedding
                guard value.type == embedding.type, value.isValid, let example = metadata[sample.speakerID] else {
                    return nil
                }
                return evidence(example, embedding: value)
            } ?? []
        guard existing.count == own.count, let candidate, let proposal = evidence(candidate, embedding: embedding)
        else {
            return .insufficientEvidence
        }
        // A full active profile can improve. Compare diversity within its existing
        // budget instead of rejecting every later reference because it is full.
        // PCM suitability was checked before this admission decision.
        guard VoiceProfileSelection.select(existing + [proposal]).contains(where: { $0.id == proposal.id }) else {
            return .alreadyRepresented
        }
        return nil
    }
}
