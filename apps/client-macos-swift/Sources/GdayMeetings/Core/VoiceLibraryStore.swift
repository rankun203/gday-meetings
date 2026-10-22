import Combine
import Foundation

/// Matching needs only whether a conflicting review exists, not every overlapping pair.
/// Library metadata has unique example IDs. A nil person remains a distinct review decision.
enum VoiceReviewConflicts {
    private struct Recording: Hashable {
        var meetingID: UUID
        var audioRevision: String?
        var audioFile: String
    }
    private struct Span {
        var id: UUID
        var personID: UUID?
        var start: Double
        var end: Double
    }
    private struct Extremes {
        struct Value {
            var personID: UUID?
            var boundary: Double
        }
        var first: Value?
        var second: Value?

        func otherBoundary(than personID: UUID?) -> Double {
            guard let first else { return -.infinity }
            return first.personID != personID ? first.boundary : (second?.boundary ?? -.infinity)
        }

        mutating func insert(personID: UUID?, boundary: Double) {
            let value = Value(personID: personID, boundary: boundary)
            if let first, first.personID == personID {
                if boundary > first.boundary { self.first = value }
            }
            else if let second, second.personID == personID {
                if boundary > second.boundary { self.second = value }
                if let first, let second = self.second, second.boundary > first.boundary {
                    self.first = second
                    self.second = first
                }
            }
            else if first == nil {
                first = value
            }
            else if boundary > first!.boundary {
                second = first
                first = value
            }
            else if second == nil || boundary > second!.boundary {
                second = value
            }
        }
    }

    static func confirmedExampleIDs(in examples: [VoiceExample]) -> Set<UUID> {
        var recordings: [Recording: [Span]] = [:]
        for example in examples where example.review == .confirmed && !example.excluded {
            guard let range = example.range else { continue }
            let recording = Recording(
                meetingID: example.meetingID, audioRevision: example.audioRevision, audioFile: range.audioFile)
            for span in range.supportSpans {
                recordings[recording, default: []].append(
                    .init(id: example.id, personID: example.personID, start: span.start, end: span.end))
            }
        }
        var conflicts = Set<UUID>()
        for spans in recordings.values {
            let ordered = spans.sorted { $0.start < $1.start }
            var prior = Extremes()
            for span in ordered {
                if prior.otherBoundary(than: span.personID) > span.start { conflicts.insert(span.id) }
                prior.insert(personID: span.personID, boundary: span.end)
            }
            var following = Extremes()
            for span in ordered.reversed() {
                // Negated starts reuse the same maximum operation to find the
                // earliest later start belonging to a different person.
                if following.otherBoundary(than: span.personID) > -span.end { conflicts.insert(span.id) }
                following.insert(personID: span.personID, boundary: -span.start)
            }
        }
        return conflicts
    }
}

@MainActor
final class VoiceLibraryStore: ObservableObject {
    @Published private(set) var examples: [VoiceExample] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var reviewUndoID: UUID?
    var reviewUndoCreatedPerson: Person? { document.undo.last?.createdPerson }
    var reviewUndoExampleIDs: Set<UUID> { Set(document.undo.last?.examples.map(\.id) ?? []) }
    @Published private(set) var jobs: [VoicePreparationJob] = []
    private var jobTimeEstimates: [UUID: Double] = [:]
    @Published private(set) var isLoaded = false
    private(set) var decisions: [VoiceSpeakerDecision] = []
    private var document = VoiceLibraryDocument()
    private let url: URL
    private let canWrite: () -> Bool
    private var persistence: VoiceLibraryPersistence?
    enum Loading { case deferred, immediate }
    // The worker exclusively owns this backend until it returns. After the
    // handoff, only the main actor accesses it through the existing write gate.
    private struct LoadedState: @unchecked Sendable {
        var persistence: VoiceLibraryPersistence?
        var document = VoiceLibraryDocument()
        var errorMessage: String?
    }
    private var loadingTask: Task<LoadedState, Never>?
    private let writeOverride: (@Sendable (Data, URL) throws -> Void)?
    private let beforeLoad: (@Sendable () throws -> Void)?
    private let matchingWorker = VoiceMatchingWorker()
    private var latestSuggestionPolicy: VoiceMatchingPolicy = .default
    /// Test seam executed on the worker, never while holding a filesystem lock.
    var beforeMatchingRead: (@Sendable () throws -> Void)?
    var beforeMatchingValidation: (@Sendable () throws -> Void)?
    var beforeObservationPreparation: (@Sendable () throws -> Void)?
    var beforeObservationCommit: (@Sendable () throws -> Void)?
    private struct MatchingOperation {
        var id = UUID()
        var input: VoiceMatchingWorker.Input
        var task: Task<VoiceMatchingWorker.Output, Error>
        var waiters: Set<UUID> = []
    }
    private var matchingOperations: [Bool: MatchingOperation] = [:]
    private var hydratedIDs: Set<UUID> = []
    private var exampleIndices: [UUID: Int] = [:]
    private var personExampleIDs: [UUID: Set<UUID>] = [:]
    private var exactExampleIDs: [VoiceExactReviewDecisions.Key: Set<UUID>] = [:]
    @Published private(set) var representationsRevision = 0
    @Published private(set) var reviewEvidenceRevision = 0
    @Published private(set) var reviewMetadataRevision = 0
    private var publishedRepresentationsRevision = 0
    private var reviewRepresentationRefresh: Task<Void, Never>?
    private var reviewRepresentationRefreshStarted: Date?
    private var reviewSnapshotReaders = 0
    /// Read seams run on the worker, outside filesystem locks.
    var beforeReviewRead: (@Sendable () throws -> Void)?
    var beforeReviewValidation: (@Sendable () throws -> Void)?
    private struct ReviewEvidence: Sendable {
        var metadata: [VoiceExample]
        var hydrated: [VoiceExample]
        var playableIDs: Set<UUID>
    }
    private struct ReviewRead {
        var id = UUID()
        var revision: Int
        var task: Task<ReviewEvidence, Error>
    }
    private var reviewRead: ReviewRead?
    private var reviewEvidence: ReviewEvidence?
    private struct ReviewSnapshotKey: Hashable {
        var people: Set<UUID>
        var policy: VoiceMatchingPolicy
        var includeUnnamedGroups: Bool
    }
    private var reviewSnapshots: [ReviewSnapshotKey: VoiceReviewSnapshot] = [:]
    private struct ReviewSnapshotOperation {
        var id = UUID()
        var revision: Int
        var task: Task<VoiceReviewSnapshot, Error>
        var readers: Set<UUID> = []
    }
    private struct ReviewGroupOperation {
        var id = UUID()
        var revision: Int
        var task: Task<[VoiceIdentificationGroup], Error>
        var readers: Set<UUID> = []
    }
    private var reviewSnapshotOperations: [ReviewSnapshotKey: ReviewSnapshotOperation] = [:]
    private var reviewGroupOperations: [VoiceMatchingPolicy: ReviewGroupOperation] = [:]
    private var reviewGroups: [VoiceMatchingPolicy: [VoiceIdentificationGroup]] = [:]
    private var previousReviewGroups: [VoiceMatchingPolicy: [VoiceIdentificationGroup]] = [:]
    var beforeReviewGrouping: (@Sendable () -> Void)?
    private(set) var reviewGroupingComputationCount = 0
    private var readable = true
    private var unavailableError: String?
    private var pendingDocument: VoiceLibraryDocument?
    private var canonicalCommitInFlight = false
    private struct ProjectionCacheEntry {
        var input: Meeting
        var output: Meeting
        var revision: Int
        var deletedPeopleRevision: Int
    }
    private var projectionCache: [UUID: ProjectionCacheEntry] = [:]
    private var projectionExamples: [UUID: [VoiceExample]] = [:]
    private struct ProjectionEvidence: Equatable {
        var id: UUID
        var range: VoiceSampleRange?
        var audioRevision: String?
        var confirmed: Bool
        var transcriptAssociation: VoiceTranscriptAssociation?
        var speakerID: UUID
        var detectedSpeakerResultID: UUID?
        var detectedSpeakerConfiguration: VoiceDiscoveryConfiguration?
        var detectedSpeakerSpans: [SpeakerEvidenceSpan]?
        var personID: UUID?
        var rejectedPersonIDs: Set<UUID>
        var manuallyCleared: Bool
        var excluded: Bool
        init(_ value: VoiceExample) {
            id = value.id
            range = value.range
            audioRevision = value.audioRevision
            confirmed = value.review == .confirmed
            transcriptAssociation = value.transcriptAssociation
            speakerID = value.speakerID
            detectedSpeakerResultID = value.detectedSpeakerResultID
            detectedSpeakerConfiguration = value.detectedSpeakerConfiguration
            detectedSpeakerSpans = value.detectedSpeakerSpans
            excluded = value.excluded
            personID = value.personID
            rejectedPersonIDs = Set(value.rejectedPersonIDs)
            manuallyCleared = value.manuallyCleared
        }
    }
    private var projectionEvidence: [UUID: [ProjectionEvidence]] = [:]
    private var projectionAudioFiles: [UUID: Set<String>] = [:]
    private var projectionDecisions: [UUID: [VoiceSpeakerDecision]] = [:]
    private var projectionRevisions: [UUID: Int] = [:]
    private var projectionDeletedPeopleRevision = 0
    /// Runs off the main actor before audio validation and projection work.
    var beforeProjectionRead: (@Sendable () -> Void)?
    private(set) var projectionComputationCount = 0
    private var deletedPeople: [UUID] = []
    var deletedPersonIDs: Set<UUID> { Set(deletedPeople) }
    var didChange: ((Set<UUID>) -> Void)?
    var didChangeProjection: ((Set<UUID>) -> Void)?

    init(
        loading: Loading = .deferred, directory: URL, canWrite: @escaping () -> Bool = { true },
        write: (@Sendable (Data, URL) throws -> Void)? = nil,
        beforeLoad: (@Sendable () throws -> Void)? = nil
    ) {
        url = directory.appendingPathComponent("voice-library")
        self.canWrite = canWrite
        writeOverride = write
        self.beforeLoad = beforeLoad
        if loading == .immediate {
            adopt(
                Self.load(
                    directory: directory, writable: canWrite(), write: write, beforeLoad: beforeLoad,
                    recoverInterruptedJobs: false))
        }
    }

    /// Shares one load across concurrent callers. Cancellation of a caller must
    /// not cancel library recovery or publish a partial document.
    @discardableResult
    func awaitReady() async -> Bool {
        if !isLoaded {
            if loadingTask == nil {
                let directory = url.deletingLastPathComponent()
                let writable = canWrite()
                let write = writeOverride
                let beforeLoad = beforeLoad
                loadingTask = Task.detached(priority: .utility) {
                    Self.load(
                        directory: directory, writable: writable, write: write, beforeLoad: beforeLoad,
                        recoverInterruptedJobs: true)
                }
            }
            if let task = loadingTask {
                let state = await task.value
                if !isLoaded { adopt(state) }
            }
        }
        if !readable, errorMessage != unavailableError { errorMessage = unavailableError }
        return readable && isLoaded
    }

    /// Workflows whose saved text does not depend on voice data still wait for
    /// loading to finish, but can continue when voice storage is unavailable.
    func awaitLoaded() async {
        _ = await awaitReady()
    }

    private nonisolated static func load(
        directory: URL, writable: Bool, write: (@Sendable (Data, URL) throws -> Void)?,
        beforeLoad: (@Sendable () throws -> Void)?, recoverInterruptedJobs: Bool
    ) -> LoadedState {
        do {
            try beforeLoad?()
            let persistence = try VoiceLibraryPersistence(directory: directory, writable: writable, write: write)
            var document = try persistence.load() ?? VoiceLibraryDocument()
            if recoverInterruptedJobs {
                let previous = document
                for index in document.jobs.indices
                where document.jobs[index].state == .running || document.jobs[index].state == .queued {
                    document.jobs[index].state = .paused
                }
                if previous.jobs != document.jobs {
                    // Checkpoint only jobs; representations remain unopened.
                    var previousJobs = VoiceLibraryDocument()
                    previousJobs.jobs = previous.jobs
                    var nextJobs = VoiceLibraryDocument()
                    nextJobs.jobs = document.jobs
                    if writable { try persistence.commit(previous: previousJobs, next: nextJobs) }
                }
            }
            return LoadedState(persistence: persistence, document: document)
        }
        catch {
            return LoadedState(errorMessage: "Couldn’t open the voice library. \(error.localizedDescription)")
        }
    }

    private func adopt(_ state: LoadedState) {
        persistence = state.persistence
        document = state.document
        readable = state.errorMessage == nil
        unavailableError = state.errorMessage
        errorMessage = state.errorMessage
        publish()
        isLoaded = true
        loadingTask = nil
    }

    /// Await readiness before voice actions. Representations are read only when a
    /// selected example or an explicit association operation needs them.
    func hydratedExample(id: UUID) -> VoiceExample? {
        guard !canonicalCommitInFlight else { return nil }
        guard let persistence, let index = exampleIndices[id] else { return nil }
        if !hydratedIDs.contains(id) {
            do {
                if let representation = try persistence.loadRepresentations(exampleID: id) {
                    document.examples[index].embeddings = representation.embeddings
                }
                hydratedIDs.insert(id)
            }
            catch {
                errorMessage = "Couldn’t load this voice example. \(error.localizedDescription)"
                return nil
            }
        }
        return document.examples[index]
    }

    func hydratedExamples(ids: Set<UUID>) -> [VoiceExample] {
        ids.sorted { $0.uuidString < $1.uuidString }.compactMap { hydratedExample(id: $0) }
    }

    func releaseRepresentations() {
        for id in hydratedIDs {
            guard let index = exampleIndices[id] else { continue }
            document.examples[index].embeddings = []
        }
        hydratedIDs.removeAll()
    }

    @discardableResult
    private func publish() -> Set<UUID> {
        let metadata = document.examples.map { example in
            var value = example
            value.embeddings = []
            return value
        }
        let affected = updateProjectionEvidence(metadata: metadata)
        let representationsChanged = publishedRepresentationsRevision != representationsRevision
        publishedRepresentationsRevision = representationsRevision
        if examples != metadata || deletedPeople != document.deletedPersonIDs {
            invalidateReviewAudio()
        }
        else if representationsChanged {
            scheduleReviewRepresentationRefresh()
        }
        deletedPeople = document.deletedPersonIDs
        if examples != metadata {
            examples = metadata
            exampleIndices = Dictionary(uniqueKeysWithValues: metadata.enumerated().map { ($0.element.id, $0.offset) })
            personExampleIDs = [:]
            exactExampleIDs = [:]
            for example in metadata {
                if let key = VoiceExactReviewDecisions.Key(example) {
                    exactExampleIDs[key, default: []].insert(example.id)
                }
                for personID in [example.personID, example.suggestedPersonID, example.namedPersonID].compactMap({ $0 })
                {
                    personExampleIDs[personID, default: []].insert(example.id)
                }
            }
            hydratedIDs.formIntersection(exampleIndices.keys)
        }
        if decisions != document.decisions { decisions = document.decisions }
        canUndo = !document.undo.isEmpty
        reviewUndoID = document.undo.last?.id
        publishJobs()
        return affected
    }

    private func commit(_ next: VoiceLibraryDocument, changed: Set<UUID> = []) -> Bool {
        guard admitVoiceWrite() else { return false }
        guard !canonicalCommitInFlight, pendingDocument == nil, readable, canWrite(), let persistence else {
            errorMessage = "The voice library is read-only. Check the data folder before saving changes."
            return false
        }
        do {
            try persistence.commit(previous: document, next: next)
            let reviewed = Self.reviewChangeMeetingIDs(previous: document, next: next).union(changed)
            let affected = publishCommittedVoiceDocument(next, warning: persistence.maintenanceWarning)
            notifyProjectionChanges(affected: affected, reviewed: reviewed)
            return true
        }
        catch {
            errorMessage = "Couldn’t save the voice library. \(error.localizedDescription)"
            return false
        }
    }

    private func publishCommittedVoiceDocument(_ next: VoiceLibraryDocument, warning: String?) -> Set<UUID> {
        let changedRepresentations = next.examples.contains { value in
            guard let index = exampleIndices[value.id] else {
                return !value.embeddings.isEmpty
            }
            return document.examples[index].embeddings != value.embeddings
        }
        document = next
        if changedRepresentations { representationsRevision += 1 }
        errorMessage = warning
        let affected = publish()
        hydratedIDs.formUnion(
            document.examples.filter { !$0.embeddings.isEmpty }.map(\.id))
        releaseRepresentations()
        return affected
    }

    private func notifyProjectionChanges(affected: Set<UUID>, reviewed: Set<UUID>) {
        if !reviewed.isEmpty { didChange?(reviewed) }
        let projectionOnly = affected.subtracting(reviewed)
        if !projectionOnly.isEmpty { didChangeProjection?(projectionOnly) }
    }

    private static func reviewChangeMeetingIDs(previous: VoiceLibraryDocument, next: VoiceLibraryDocument) -> Set<UUID>
    {
        let before = Dictionary(uniqueKeysWithValues: previous.examples.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: next.examples.map { ($0.id, $0) })
        var changed = Set<UUID>()
        for id in Set(before.keys).union(after.keys) {
            if let lhs = before[id], let rhs = after[id] {
                if !lhs.hasSameReviewEvidence(as: rhs) { changed.formUnion([lhs.meetingID, rhs.meetingID]) }
            }
            else if let value = before[id] ?? after[id], value.isReviewed || value.namedPersonID != nil {
                changed.insert(value.meetingID)
            }
        }
        if previous.decisions != next.decisions {
            let changedDecisions = Set(previous.decisions).symmetricDifference(Set(next.decisions))
            changed.formUnion(changedDecisions.map(\.meetingID))
        }
        return changed
    }

    @discardableResult
    func upsert(_ incoming: [VoiceExample], staged: Bool = false) -> Bool {
        defer { if !staged { releaseRepresentations() } }
        if staged, !admitVoiceWrite() { return false }
        for value in incoming where !value.embeddings.isEmpty {
            if document.examples.contains(where: { $0.id == value.id }), hydratedExample(id: value.id) == nil {
                return false
            }
        }
        var next = document
        for value in incoming {
            if let index = next.examples.firstIndex(where: { $0.id == value.id }) {
                // Preparation may finish after review. Representations and
                // exact-audio quality can change without replacing decisions.
                guard next.examples[index].range == value.range else { continue }
                if next.examples[index].audioRevision == value.audioRevision,
                    let quality = value.currentSampleQuality
                {
                    next.examples[index].sampleQuality = quality
                }
                if next.examples[index].audioRevision == value.audioRevision {
                    next.examples[index].detectedSpeakerSpans = value.detectedSpeakerSpans
                    next.examples[index].detectedSpeakerID = value.detectedSpeakerID
                    next.examples[index].detectedSpeakerResultID = value.detectedSpeakerResultID
                    next.examples[index].detectedSpeakerConfiguration = value.detectedSpeakerConfiguration
                }
                for embedding in value.embeddings where embedding.isValid {
                    if next.examples[index].embeddings.first(where: { $0.type == embedding.type }) == embedding {
                        continue
                    }
                    next.examples[index].transcriptAssociation = nil
                    next.examples[index].embeddings.removeAll { $0.type == embedding.type }
                    next.examples[index].embeddings.append(embedding)
                }
            }
            else {
                next.examples.append(value)
            }
        }
        if staged {
            // Even an unchanged retry reserves voice writes until meeting publication finishes.
            pendingDocument = next
            return true
        }
        guard next.examples != document.examples else { return true }
        return commit(next)
    }

    @discardableResult
    func addRepresentation(exampleID: UUID, embedding: TypedVoiceEmbedding) -> Bool {
        guard embedding.isValid, var example = examples.first(where: { $0.id == exampleID }), audioIsCurrent(example)
        else { return false }
        example.embeddings = [embedding]
        return upsert([example])
    }

    func examples(for personID: UUID) -> [VoiceExample] {
        (personExampleIDs[personID] ?? []).compactMap { id in exampleIndices[id].map { examples[$0] } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// A captured question also depends on decisions stored on exact aliases.
    func reviewEvidence(for requestedIDs: Set<UUID>) -> [VoiceExample] {
        var ids = requestedIDs
        for id in requestedIDs {
            guard let index = exampleIndices[id], let key = VoiceExactReviewDecisions.Key(examples[index]) else {
                continue
            }
            ids.formUnion(exactExampleIDs[key] ?? [])
        }
        return ids.compactMap { id in exampleIndices[id].map { examples[$0] } }
    }

    /// Reference projection also needs exact aliases with cleared identities or
    /// rejections. Resolve that small evidence set through publication indexes.
    func referenceEvidence(for personID: UUID) -> [VoiceExample] {
        let associated = examples(for: personID)
        var ids = Set(associated.map(\.id))
        for example in associated {
            if let key = VoiceExactReviewDecisions.Key(example) {
                ids.formUnion(exactExampleIDs[key] ?? [])
            }
        }
        return ids.compactMap { id in exampleIndices[id].map { examples[$0] } }
    }

    /// Excerpt decisions update selected evidence and compatible exact aliases.
    /// Whole-speaker edits use assign(meetingID:speakerID:personID:) explicitly.
    private func edit(ids: Set<UUID>, _ change: (inout VoiceExample) -> Void) -> Bool {
        guard !ids.isEmpty else { return false }
        var next = document
        next.undo.append(
            .init(
                examples: document.examples.filter { ids.contains($0.id) }.map(VoiceExampleReviewSnapshot.init),
                decisions: document.decisions))
        next.undo = Array(next.undo.suffix(20))
        var changed = Set<UUID>()
        for index in next.examples.indices where ids.contains(next.examples[index].id) {
            next.examples[index].transcriptAssociation = nil
            change(&next.examples[index])
            changed.insert(next.examples[index].meetingID)
        }
        guard !changed.isEmpty else { return false }
        return commit(next, changed: changed)
    }

    /// Equivalent records retain provider provenance, but one excerpt decision
    /// updates compatible aliases in the same transaction and Undo snapshot.
    /// A different explicit identity remains a visible conflict for review.
    private func exactReviewIDs(_ ids: Set<UUID>) -> Set<UUID> {
        var identities: [VoiceExactReviewDecisions.Key: Set<UUID?>] = [:]
        for example in document.examples where ids.contains(example.id) {
            if let key = VoiceExactReviewDecisions.Key(example) {
                identities[key, default: []].insert(example.personID ?? example.namedPersonID)
            }
        }
        var result = ids
        for example in document.examples {
            guard let key = VoiceExactReviewDecisions.Key(example), let selected = identities[key] else { continue }
            let identity = example.personID ?? example.namedPersonID
            if identity == nil || selected.contains(identity) { result.insert(example.id) }
        }
        return result
    }

    @discardableResult
    func confirm(ids: Set<UUID>, personID: UUID) -> Bool {
        guard !document.deletedPersonIDs.contains(personID) else { return false }
        return edit(ids: exactReviewIDs(ids)) {
            if let previous = $0.personID ?? $0.namedPersonID ?? $0.suggestedPersonID,
                previous != personID, !$0.rejectedPersonIDs.contains(previous)
            {
                $0.rejectedPersonIDs.append(previous)
            }
            $0.personID = personID
            $0.namedPersonID = nil
            $0.suggestedPersonID = nil
            $0.review = .confirmed
            $0.rejectedPersonIDs.removeAll { $0 == personID }
            $0.excluded = false
            $0.manuallyCleared = false
        }
    }

    /// Naming a proposed group is one reversible action. Only an explicitly
    /// confirmed excerpt contributes identity evidence to automatic matching.
    @discardableResult
    func nameGroup(
        ids: Set<UUID>, confirmedExampleID: UUID?, personID: UUID,
        createdPerson: Person? = nil, staged: Bool = false
    ) -> Bool {
        guard admitVoiceWrite(), !document.deletedPersonIDs.contains(personID), !ids.isEmpty,
            confirmedExampleID.map(ids.contains) ?? true
        else { return false }
        let anchorIDs = confirmedExampleID.map { exactReviewIDs([$0]) } ?? []
        // Explicitly naming one stored sample has the same restorative intent
        // as Confirm. Naming a proposed group still respects other exclusions.
        let namesSingleSample = confirmedExampleID.map { ids == Set([$0]) } ?? false
        let associatedIDs = ids.union(anchorIDs)
        let indices = document.examples.indices.filter { associatedIDs.contains(document.examples[$0].id) }
        guard indices.count == associatedIDs.count else { return false }
        let exactDecisions = VoiceExactReviewDecisions(document.examples)
        let eligible = indices.filter {
            let original = document.examples[$0]
            let example = exactDecisions.applying(to: original)
            let anchor = anchorIDs.contains(example.id)
            if namesSingleSample && anchor { return true }
            return !example.excluded && (!example.manuallyCleared || (anchor && !original.manuallyCleared))
                && (!example.rejectedPersonIDs.contains(personID) || anchorIDs.contains(example.id))
                && (example.personID == nil || example.personID == personID || anchorIDs.contains(example.id))
        }
        guard !eligible.isEmpty,
            confirmedExampleID.map({ id in eligible.contains { document.examples[$0].id == id } }) ?? true
        else { return false }
        var next = document
        next.undo.append(
            .init(
                createdPerson: createdPerson,
                examples: eligible.map { VoiceExampleReviewSnapshot(document.examples[$0]) },
                decisions: document.decisions))
        next.undo = Array(next.undo.suffix(20))
        let groupID = eligible.map { document.examples[$0].groupID }.min { $0.uuidString < $1.uuidString }!
        for index in eligible {
            next.examples[index].transcriptAssociation = nil
            next.examples[index].groupID = groupID
            next.examples[index].manuallyGrouped = true
            if anchorIDs.contains(next.examples[index].id) {
                let previous =
                    next.examples[index].personID ?? next.examples[index].namedPersonID
                    ?? next.examples[index].suggestedPersonID
                if let previous, previous != personID, !next.examples[index].rejectedPersonIDs.contains(previous) {
                    next.examples[index].rejectedPersonIDs.append(previous)
                }
                next.examples[index].rejectedPersonIDs.removeAll { $0 == personID }
                next.examples[index].personID = personID
                next.examples[index].namedPersonID = nil
                next.examples[index].suggestedPersonID = nil
                next.examples[index].review = .confirmed
                next.examples[index].excluded = false
                next.examples[index].manuallyCleared = false
            }
            else if next.examples[index].review != .confirmed {
                next.examples[index].namedPersonID = personID
                next.examples[index].suggestedPersonID = personID
                next.examples[index].review = .suggested
            }
        }
        if staged {
            pendingDocument = next
            return true
        }
        return commit(next, changed: Set(eligible.map { document.examples[$0].meetingID }))
    }

    @discardableResult
    func reject(ids: Set<UUID>, personID: UUID, restoreExcluded: Bool = false) -> Bool {
        edit(ids: exactReviewIDs(ids)) {
            // Correcting Ignore to an identity rejection restores the excerpt for
            // other people in the same atomic, reversible decision.
            if restoreExcluded { $0.excluded = false }
            if !$0.rejectedPersonIDs.contains(personID) { $0.rejectedPersonIDs.append(personID) }
            if $0.personID == personID { $0.personID = nil }
            if $0.namedPersonID == personID { $0.namedPersonID = nil }
            if $0.suggestedPersonID == personID { $0.suggestedPersonID = nil }
            $0.review = $0.personID == nil ? .rejected : .confirmed
        }
    }

    @discardableResult
    // Removing an association applies to compatible records of the same audio,
    // so profile evidence and review presentation retain the same decision.
    func clear(ids: Set<UUID>) -> Bool {
        edit(ids: exactReviewIDs(ids)) {
            $0.personID = nil
            $0.namedPersonID = nil
            $0.suggestedPersonID = nil
            $0.review = .unassigned
            $0.manuallyCleared = true
        }
    }

    @discardableResult
    func exclude(ids: Set<UUID>, excluded: Bool = true) -> Bool {
        edit(ids: exactReviewIDs(ids)) { $0.excluded = excluded }
    }

    @discardableResult
    func merge(ids: Set<UUID>) -> Bool {
        let group = UUID()
        return edit(ids: ids) {
            $0.groupID = group
            $0.manuallyGrouped = true
        }
    }

    @discardableResult
    func split(ids: Set<UUID>) -> Bool {
        let group = UUID()
        return edit(ids: ids) {
            $0.groupID = group
            $0.manuallyGrouped = true
        }
    }

    @discardableResult
    func groupSuggestions(ids: Set<UUID>) -> Bool {
        let group = UUID()
        var next = document
        let eligible = next.examples.indices.filter {
            ids.contains(next.examples[$0].id) && !next.examples[$0].manuallyGrouped
                && !next.examples[$0].isReviewed && next.examples[$0].rejectedPersonIDs.isEmpty
        }
        guard eligible.count > 1 else { return true }
        for index in eligible { next.examples[index].groupID = group }
        return commit(next)
    }

    /// Estimates are presentation state. Updating one must not write a recovery checkpoint.
    func setJobTimeEstimate(_ estimate: Double?, jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .running else { return }
        jobTimeEstimates[jobID] = estimate
        guard jobs[index].estimatedRemainingSeconds != estimate else { return }
        jobs[index].estimatedRemainingSeconds = estimate
    }

    private func publishJobs() {
        let active = Set(
            document.jobs.filter { $0.state == .running && $0.progressPhase == "Preparing voice examples" }.map(\.id))
        jobTimeEstimates = jobTimeEstimates.filter { active.contains($0.key) }
        let presented = document.jobs.map { job in
            var value = job
            value.estimatedRemainingSeconds = jobTimeEstimates[job.id]
            return value
        }
        if jobs != presented { jobs = presented }
    }

    @discardableResult
    func setJobs(_ jobs: [VoicePreparationJob]) -> Bool {
        let jobs = jobs.map { job in
            var value = job
            value.estimatedRemainingSeconds = nil
            return value
        }
        guard isLoaded else { return false }
        guard jobs != document.jobs else { return true }
        guard admitVoiceWrite() else { return false }
        guard !canonicalCommitInFlight, pendingDocument == nil, readable, canWrite(), let persistence else {
            errorMessage = "The voice library is read-only. Check the data folder before saving changes."
            return false
        }
        // A progress checkpoint is a jobs-only delta. It neither visits example
        // metadata nor reads or compares any cached voice representations.
        var previous = VoiceLibraryDocument()
        previous.jobs = document.jobs
        var next = VoiceLibraryDocument()
        next.jobs = jobs
        do {
            try persistence.commit(previous: previous, next: next)
            document.jobs = jobs
            publishJobs()
            errorMessage = persistence.maintenanceWarning
            return true
        }
        catch {
            errorMessage = "Couldn’t save voice preparation progress. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func undo(expectedUndoID: UUID? = nil, staged: Bool = false) -> Bool {
        guard let previous = document.undo.last,
            expectedUndoID == nil || previous.id == expectedUndoID
        else { return false }
        if staged, !admitVoiceWrite() { return false }
        var next = document
        next.undo.removeLast()
        // Keep newly discovered evidence and embeddings from background work.
        for state in previous.examples {
            if let index = next.examples.firstIndex(where: { $0.id == state.id }) {
                state.restore(&next.examples[index])
            }
        }
        next.decisions = previous.decisions
        if let created = previous.createdPerson {
            if !next.deletedPersonIDs.contains(created.id) { next.deletedPersonIDs.append(created.id) }
            for index in next.examples.indices {
                if next.examples[index].transcriptAssociation?.personID == created.id {
                    next.examples[index].transcriptAssociation = nil
                }
                if next.examples[index].suggestedPersonID == created.id {
                    next.examples[index].suggestedPersonID = nil
                }
            }
        }
        let changedDecisions = Set(document.decisions).symmetricDifference(Set(previous.decisions))
        let restoredIDs = Set(previous.examples.map(\.id))
        let changedMeetings = Set(next.examples.filter { restoredIDs.contains($0.id) }.map(\.meetingID))
            .union(changedDecisions.map(\.meetingID))
        if staged {
            pendingDocument = next
            return true
        }
        return commit(next, changed: changedMeetings)
    }

    /// Confirmed samples are usable with the model that produced them, even
    /// when their source recording is unavailable for playback.
    func matchingPeople(from people: [Person]) async throws -> [Person] {
        try await matchingResult(from: people, includeSuggestions: false).profiles
    }

    func reviewCandidates(for personID: UUID) async throws -> [VoiceExample] {
        try await reviewSnapshot(for: [personID], includeUnnamedGroups: false).candidates[personID] ?? []
    }

    func reviewCandidates(for personIDs: Set<UUID>) async throws -> [UUID: [VoiceExample]] {
        try await reviewSnapshot(for: personIDs, includeUnnamedGroups: false).candidates
    }

    /// Counts and dialogs use these exact queues. Refresh also checks recording
    /// files changed outside the library, such as a moved or replaced recording.
    func reviewSnapshot(
        for personIDs: Set<UUID>, forceRefresh: Bool = false, policy: VoiceMatchingPolicy = .default,
        includeUnnamedGroups: Bool = true
    )
        async throws -> VoiceReviewSnapshot
    {
        if forceRefresh { invalidateReviewAudio() }
        reviewSnapshotReaders += 1
        defer { reviewSnapshotReaders -= 1 }
        while true {
            let evidence = try await readReviewEvidence()
            try Task.checkCancellation()
            let activePeople = personIDs.subtracting(deletedPeople)
            let key = ReviewSnapshotKey(
                people: activePeople, policy: policy.normalized, includeUnnamedGroups: includeUnnamedGroups)
            if let cached = reviewSnapshots[key] { return cached }
            let revision = reviewEvidenceRevision
            let result: VoiceReviewSnapshot
            do {
                let groups =
                    includeUnnamedGroups
                    ? try await preparedReviewGroups(evidence, policy: key.policy, revision: revision) : []
                guard revision == reviewEvidenceRevision, reviewEvidence != nil else { continue }
                if let cached = reviewSnapshots[key] { return cached }
                if reviewSnapshotOperations[key] == nil {
                    reviewSnapshotOperations[key] = .init(
                        revision: revision,
                        task: Task.detached(priority: .utility) {
                            try Task.checkCancellation()
                            let result = VoiceReviewSnapshot.make(
                                hydrated: evidence.hydrated, metadata: evidence.metadata,
                                playableIDs: evidence.playableIDs, personIDs: activePeople, revision: revision,
                                policy: key.policy, preparedGroups: groups)
                            try Task.checkCancellation()
                            return result
                        })
                }
                let operation = reviewSnapshotOperations[key]!
                let reader = UUID()
                reviewSnapshotOperations[key]?.readers.insert(reader)
                defer { releaseSnapshotReader(reader, key: key, operationID: operation.id) }
                result = try await withTaskCancellationHandler {
                    try await operation.task.value
                } onCancel: {
                    Task { @MainActor [weak self] in
                        self?.releaseSnapshotReader(reader, key: key, operationID: operation.id)
                    }
                }
                try Task.checkCancellation()
            }
            catch {
                try Task.checkCancellation()
                if revision != reviewEvidenceRevision { continue }
                throw error
            }
            guard revision == reviewEvidenceRevision, reviewEvidence != nil else { continue }
            if reviewSnapshots.count >= 8 { reviewSnapshots.removeAll() }
            reviewSnapshots[key] = result
            return result
        }
    }

    /// Compatibility for workflows that inspect all stored groups. Ineligible
    /// members remain linked evidence and never become playback questions.
    func identificationGroups(policy: VoiceMatchingPolicy = .default) async throws -> [VoiceIdentificationGroup] {
        while true {
            let evidence = try await readReviewEvidence()
            let revision = reviewEvidenceRevision
            do {
                return try await preparedReviewGroups(evidence, policy: policy.normalized, revision: revision)
            }
            catch {
                try Task.checkCancellation()
                if revision != reviewEvidenceRevision { continue }
                throw error
            }
        }
    }

    private func releaseSnapshotReader(_ reader: UUID, key: ReviewSnapshotKey, operationID: UUID) {
        guard reviewSnapshotOperations[key]?.id == operationID else { return }
        reviewSnapshotOperations[key]?.readers.remove(reader)
        if reviewSnapshotOperations[key]?.readers.isEmpty == true {
            reviewSnapshotOperations[key]?.task.cancel()
            reviewSnapshotOperations[key] = nil
        }
    }

    private func releaseGroupReader(_ reader: UUID, policy: VoiceMatchingPolicy, operationID: UUID) {
        guard reviewGroupOperations[policy]?.id == operationID else { return }
        reviewGroupOperations[policy]?.readers.remove(reader)
        if reviewGroupOperations[policy]?.readers.isEmpty == true {
            reviewGroupOperations[policy]?.task.cancel()
            reviewGroupOperations[policy] = nil
        }
    }

    private func preparedReviewGroups(_ evidence: ReviewEvidence, policy: VoiceMatchingPolicy, revision: Int)
        async throws -> [VoiceIdentificationGroup]
    {
        try Task.checkCancellation()
        if let groups = reviewGroups[policy] { return groups }
        if reviewGroupOperations[policy] == nil {
            let beforeRead = beforeReviewGrouping
            let previous = previousReviewGroups[policy] ?? []
            reviewGroupingComputationCount += 1
            reviewGroupOperations[policy] = .init(
                revision: revision,
                task: Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    beforeRead?()
                    let groups = VoiceReviewSnapshot.groups(
                        hydrated: evidence.hydrated, metadata: evidence.metadata,
                        playableIDs: evidence.playableIDs, policy: policy)
                    // Grouping's synchronous cancellation sentinel must never become
                    // a published singleton/empty presentation or enter this cache.
                    try Task.checkCancellation()
                    return VoiceReviewGroupIdentity.preserving(groups, previous: previous)
                })
        }
        let operation = reviewGroupOperations[policy]!
        let reader = UUID()
        reviewGroupOperations[policy]?.readers.insert(reader)
        defer { releaseGroupReader(reader, policy: policy, operationID: operation.id) }
        let groups = try await withTaskCancellationHandler {
            try await operation.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseGroupReader(reader, policy: policy, operationID: operation.id)
            }
        }
        try Task.checkCancellation()
        guard revision == reviewEvidenceRevision, reviewEvidence != nil else { throw CancellationError() }
        if reviewGroups.count >= 4 { reviewGroups.removeAll() }
        if previousReviewGroups.count >= 4, previousReviewGroups[policy] == nil { previousReviewGroups.removeAll() }
        previousReviewGroups[policy] = groups
        reviewGroups[policy] = groups
        return groups
    }

    /// Call after a recording is deleted or its audio is replaced. Decision and
    /// audio changes invalidate immediately, including a pending model refresh.
    func invalidateReviewAudio() {
        reviewMetadataRevision += 1
        refreshReviewEvidence()
    }

    private func refreshReviewEvidence() {
        reviewRepresentationRefresh?.cancel()
        reviewRepresentationRefresh = nil
        reviewRepresentationRefreshStarted = nil
        reviewEvidenceRevision += 1
        invalidateReviewCache()
    }

    private func scheduleReviewRepresentationRefresh() {
        let now = Date()
        if reviewRepresentationRefreshStarted == nil { reviewRepresentationRefreshStarted = now }
        // Publish after 300 ms of quiet, bounding continuous batches to two
        // seconds. Let an active read finish before publishing its refresh.
        let elapsed = now.timeIntervalSince(reviewRepresentationRefreshStarted!)
        scheduleReviewRepresentationRefresh(after: max(0, min(0.3, 2 - elapsed)))
    }

    private func scheduleReviewRepresentationRefresh(after delay: Double) {
        reviewRepresentationRefresh?.cancel()
        reviewRepresentationRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self else { return }
            if self.reviewRead != nil || self.reviewSnapshotReaders > 0 {
                self.scheduleReviewRepresentationRefresh(after: 0.1)
                return
            }
            self.refreshReviewEvidence()
        }
    }

    private func invalidateReviewCache() {
        for operation in reviewSnapshotOperations.values { operation.task.cancel() }
        for operation in reviewGroupOperations.values { operation.task.cancel() }
        reviewSnapshotOperations.removeAll()
        reviewGroupOperations.removeAll()
        reviewGroups.removeAll()
        reviewRead?.task.cancel()
        reviewRead = nil
        reviewEvidence = nil
        reviewSnapshots.removeAll()
    }

    private func readReviewEvidence() async throws -> ReviewEvidence {
        while true {
            try Task.checkCancellation()
            guard await awaitReady(), let persistence else {
                throw ServiceError(errorMessage ?? "The voice library is unavailable. Try again.")
            }
            // A canonical save owns its pending document until publication.
            // Waiting keeps an expected write race out of persistent UI errors.
            if canonicalCommitInFlight || pendingDocument != nil {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            if let reviewEvidence { return reviewEvidence }
            let revision = reviewEvidenceRevision
            let snapshot = persistence.snapshot()
            if reviewRead == nil {
                let metadata = examples
                let directory = url.deletingLastPathComponent()
                let beforeRead = beforeReviewRead
                let beforeValidation = beforeReviewValidation
                reviewRead = ReviewRead(
                    revision: revision,
                    task: Task.detached(priority: .utility) {
                        let backend = try VoiceLibraryPersistence(directory: directory, writable: false)
                        backend.adopt(snapshot)
                        let exactDecisions = VoiceExactReviewDecisions(metadata)
                        let active = metadata.map { exactDecisions.applying(to: $0) }.filter {
                            !$0.excluded && !$0.manuallyCleared
                        }
                        let dependencies = try backend.profileDependencyRevisions(
                            exampleIDs: active.map(\.id), includeRepresentations: false)
                        try beforeRead?()
                        var hydrated: [VoiceExample] = []
                        var playable = Set<UUID>()
                        for original in active {
                            try Task.checkCancellation()
                            var example = original
                            if example.range != nil, example.audioRevision != nil,
                                let folder = try? MeetingFolderLocation.resolve(
                                    id: example.meetingID, directory: directory),
                                let file = example.audioFile,
                                Self.revision(url: folder.appendingPathComponent(file)) == example.audioRevision
                            {
                                playable.insert(example.id)
                            }
                            // Confirmed evidence can still identify other excerpts
                            // when its original recording is unavailable.
                            guard example.review == .confirmed || playable.contains(example.id) else { continue }
                            example.embeddings =
                                try backend.loadReviewRepresentations(
                                    exampleID: example.id, dependencies: dependencies)?.embeddings ?? []
                            hydrated.append(example)
                        }
                        try beforeValidation?()
                        try backend.validateProfileDependencies(dependencies)
                        return ReviewEvidence(metadata: metadata, hydrated: hydrated, playableIDs: playable)
                    })
            }
            let operation = reviewRead!
            do {
                let result = try await operation.task.value
                try Task.checkCancellation()
                guard reviewRead?.id == operation.id, revision == reviewEvidenceRevision,
                    !canonicalCommitInFlight, pendingDocument == nil
                else { continue }
                reviewRead = nil
                reviewEvidence = result
                return result
            }
            catch {
                try Task.checkCancellation()
                let invalidated = reviewRead?.id != operation.id
                if reviewRead?.id == operation.id { reviewRead = nil }
                if invalidated || revision != reviewEvidenceRevision
                    || persistence.snapshot().revision != snapshot.revision
                    || canonicalCommitInFlight || pendingDocument != nil
                {
                    continue
                }
                throw error
            }
        }
    }

    private func matchingResult(from people: [Person], includeSuggestions: Bool, policy: VoiceMatchingPolicy = .default)
        async throws
        -> VoiceMatchingWorker.Output
    {
        try Task.checkCancellation()
        guard readable, isLoaded, !canonicalCommitInFlight, pendingDocument == nil, let persistence else {
            throw ServiceError("The voice library is unavailable for matching.")
        }
        let snapshot = persistence.snapshot()
        let input = VoiceMatchingWorker.Input(
            directory: url.deletingLastPathComponent(), persistence: snapshot, examples: examples,
            people: people, deletedPeople: deletedPeople, includeSuggestions: includeSuggestions,
            policy: policy.normalized)
        if includeSuggestions { invalidateMatchingPolicy(input.policy) }
        for mode in Array(matchingOperations.keys) {
            guard let operation = matchingOperations[mode] else { continue }
            if operation.input.persistence.revision != snapshot.revision
                || operation.input.persistence.fileRevisions != snapshot.fileRevisions
                || operation.input.people != people
                || (mode && includeSuggestions && operation.input.policy != input.policy)
            {
                operation.task.cancel()
                matchingOperations[mode] = nil
            }
        }
        if matchingOperations[includeSuggestions] == nil {
            let worker = matchingWorker
            let beforeRead = beforeMatchingRead
            let beforeValidation = beforeMatchingValidation
            matchingOperations[includeSuggestions] = MatchingOperation(
                input: input,
                task: Task(priority: .utility) {
                    try await worker.run(input, beforeRead: beforeRead, beforeValidation: beforeValidation)
                })
        }
        let id = matchingOperations[includeSuggestions]!.id
        let token = UUID()
        matchingOperations[includeSuggestions]!.waiters.insert(token)
        let task = matchingOperations[includeSuggestions]!.task
        defer { releaseMatchingWaiter(token, operationID: id) }
        let result: VoiceMatchingWorker.Output
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { @MainActor [weak self] in self?.releaseMatchingWaiter(token, operationID: id) }
            }
        }
        catch {
            // A review made while reading is expected invalidation, not a storage failure.
            guard !Task.isCancelled, readable, !canonicalCommitInFlight, pendingDocument == nil,
                persistence.snapshot().revision == snapshot.revision,
                examples == input.examples, deletedPeople == input.deletedPeople
            else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        // No suspension between this validation and returning profiles or applying suggestions.
        guard readable, !canonicalCommitInFlight, pendingDocument == nil,
            persistence.snapshot().revision == snapshot.revision,
            persistence.snapshot().fileRevisions == snapshot.fileRevisions,
            examples == input.examples, deletedPeople == input.deletedPeople,
            !includeSuggestions || latestSuggestionPolicy == input.policy
        else { throw CancellationError() }
        return result
    }

    private func releaseMatchingWaiter(_ token: UUID, operationID: UUID) {
        guard let mode = matchingOperations.first(where: { $0.value.id == operationID })?.key else { return }
        matchingOperations[mode]?.waiters.remove(token)
        if matchingOperations[mode]?.waiters.isEmpty == true {
            matchingOperations[mode]?.task.cancel()
            matchingOperations[mode] = nil
        }
    }

    func matchingBlockReason(for example: VoiceExample) -> String? {
        hasConflictingReview(example) ? "Conflicting person assignments · Not used for matching" : nil
    }

    private func hasConflictingReview(_ example: VoiceExample) -> Bool {
        guard let range = example.range else { return false }
        return examples.contains { other in
            guard other.id != example.id, other.meetingID == example.meetingID,
                other.audioRevision == example.audioRevision, other.review == .confirmed,
                other.personID != example.personID, !other.excluded, let otherRange = other.range
            else { return false }
            return otherRange.overlaps(range)
        }
    }

    /// File identity and modification metadata invalidate replacement and edits
    /// without rereading hours of audio on the UI actor.
    nonisolated static func revision(url: URL) -> String? {
        // Full attributesOfItem also resolves owner/group accounts through
        // Directory Services. Matching checks many records while holding a file
        // lock; request only the fields used by the existing revision format.
        // A fresh URL prevents cached resource values hiding external edits.
        let fresh = URL(fileURLWithPath: url.path)
        guard
            let values = try? fresh.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ]),
            values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
            let modified = values.contentModificationDate
        else { return nil }
        return "\(size):\(modified.timeIntervalSince1970)"
    }

    func audioIsCurrent(_ example: VoiceExample) -> Bool {
        guard let range = example.range, let revision = example.audioRevision,
            let folder = try? MeetingFolderLocation.resolve(
                id: example.meetingID, directory: url.deletingLastPathComponent())
        else { return false }
        return Self.revision(url: folder.appendingPathComponent(range.audioFile)) == revision
    }

    func availabilityReason(for example: VoiceExample) -> String? {
        guard let range = example.range else {
            if let passage = example.firstPassage {
                guard
                    let folder = try? MeetingFolderLocation.resolve(
                        id: example.meetingID, directory: url.deletingLastPathComponent()),
                    Self.revision(url: folder.appendingPathComponent(passage.audioFile)) != nil
                else { return "The recording audio is unavailable." }
                return "No separate speech excerpt was found. Open the first speaker passage to review the recording."
            }
            return example.sourceResolutionIssue
                ?? "This sample has no saved audio excerpt. Find a playable example in its recording."
        }
        guard
            let folder = try? MeetingFolderLocation.resolve(
                id: example.meetingID, directory: url.deletingLastPathComponent()),
            let revision = Self.revision(url: folder.appendingPathComponent(range.audioFile))
        else { return "The recording audio is unavailable." }
        guard let recorded = example.audioRevision else {
            return "The saved excerpt has not been checked against its recording."
        }
        return recorded == revision
            ? nil : "The recording audio changed. Find a new excerpt to play this sample."
    }

    /// Locate playback audio while preserving the sample’s identity and model representations.
    @discardableResult
    func resolveLegacyExample(exampleID: UUID, meeting: Meeting, directory: URL, reportError: Bool = true)
        -> VoiceExample?
    {
        guard let index = document.examples.firstIndex(where: { $0.id == exampleID && $0.meetingID == meeting.id })
        else { return nil }
        guard let example = hydratedExample(id: exampleID) else { return nil }
        guard example.range == nil else { return example }
        guard let resolved = VoiceExampleResolution.resolve(example, meeting: meeting) else {
            if reportError {
                errorMessage =
                    "The original speaker could not be identified in this recording. Use Find Voices in Recordings to find new examples."
            }
            return nil
        }
        var next = document
        next.examples[index].firstPassage = resolved.firstPassage
        next.examples[index].sourceResolutionIssue = resolved.unavailableReason
        if let range = resolved.range, range.isValid,
            let revision = Self.revision(url: directory.appendingPathComponent(range.audioFile))
        {
            let sourceChanged = meeting.speakers.contains { speaker in
                (speaker.id == resolved.speakerID || speaker.voiceReviewOrigin?.speakerID == resolved.speakerID)
                    && speaker.voiceSampleRange?.audioFile == range.audioFile
                    && speaker.voiceSampleRevision.map { $0 != revision } == true
            }
            if sourceChanged {
                next.examples[index].firstPassage = nil
                next.examples[index].sourceResolutionIssue =
                    "The recording audio changed. Find a new excerpt to play this sample."
            }
            else {
                next.examples[index].transcriptAssociation = nil
                next.examples[index].detectedSpeakerID = nil
                next.examples[index].detectedSpeakerSpans = nil
                next.examples[index].audioFile = range.audioFile
                next.examples[index].audioRevision = revision
                next.examples[index].start = range.start
                next.examples[index].end = range.end
                next.examples[index].spans = range.spans
                next.examples[index].source = range.source
                next.examples[index].speakerID = resolved.speakerID
            }
        }
        let changed: Set<UUID> = example.review == .rejected || example.manuallyCleared ? [meeting.id] : []
        guard next.examples == document.examples || commit(next, changed: changed) else { return nil }
        return hydratedExample(id: exampleID)
    }

    func suggestReviewedPeople(from people: [Person], policy: VoiceMatchingPolicy = .default) async {
        do { try await suggestReviewedPeopleResult(from: people, policy: policy) }
        catch is CancellationError {}
        catch {
            errorMessage = "Couldn’t prepare voice matches. \(error.localizedDescription)"
        }
    }

    /// Settings invalidate an older matching publication before the coalesced
    /// refresh reaches its worker. Reviewed profiles and embeddings remain valid.
    func invalidateMatchingPolicy(_ policy: VoiceMatchingPolicy) {
        guard latestSuggestionPolicy != policy.normalized else { return }
        latestSuggestionPolicy = policy.normalized
        let affected = Set(
            projectionExamples.compactMap { id, examples in
                examples.contains { $0.transcriptAssociation != nil } ? id : nil
            })
        invalidateDecisionProjections(meetingIDs: affected)
        if !affected.isEmpty { didChangeProjection?(affected) }
        if let operation = matchingOperations[true], operation.input.policy != latestSuggestionPolicy {
            operation.task.cancel()
            matchingOperations[true] = nil
        }
    }

    func suggestReviewedPeopleResult(from people: [Person], policy: VoiceMatchingPolicy = .default) async throws {
        let result = try await matchingResult(from: people, includeSuggestions: true, policy: policy)
        try Task.checkCancellation()
        var next = document
        for suggestion in result.suggestions {
            guard let index = exampleIndices[suggestion.exampleID], next.examples[index].acceptsSuggestions else {
                continue
            }
            let personID = next.examples[index].namedPersonID ?? suggestion.personID
            next.examples[index].suggestedPersonID = personID
            let association = suggestion.transcriptAssociation
            next.examples[index].transcriptAssociation =
                association?.isValid == true
                    && (next.examples[index].namedPersonID == nil
                        || next.examples[index].namedPersonID == association?.personID)
                ? association : nil
            next.examples[index].review = personID == nil ? .unassigned : .suggested
        }
        if next.examples != document.examples, !commit(next) {
            throw ServiceError(errorMessage ?? "Couldn’t save voice matches.")
        }
    }

    @discardableResult
    func suggest(exampleID: UUID, personID: UUID?) -> Bool {
        defer { releaseRepresentations() }
        guard let index = document.examples.firstIndex(where: { $0.id == exampleID }),
            document.examples[index].acceptsSuggestions
        else { return true }
        let candidate = allowedSuggestion(
            for: document.examples[index], personID: document.examples[index].namedPersonID ?? personID)
        var next = document
        guard next.examples[index].suggestedPersonID != candidate || next.examples[index].transcriptAssociation != nil
        else { return true }
        next.examples[index].transcriptAssociation = nil
        next.examples[index].suggestedPersonID = candidate
        next.examples[index].review = candidate == nil ? .unassigned : .suggested
        return commit(next)
    }

    private func allowedSuggestion(for example: VoiceExample, personID: UUID?) -> UUID? {
        let effective = VoiceExactReviewDecisions(document.examples).applying(to: example)
        guard let personID, !document.deletedPersonIDs.contains(personID),
            effective.acceptsSuggestions, !effective.rejectedPersonIDs.contains(personID)
        else { return nil }
        return personID
    }

    @discardableResult
    func ingest(meeting: Meeting, directory: URL) -> Bool {
        for example in examples
        where example.meetingID == meeting.id && example.range == nil {
            _ = resolveLegacyExample(exampleID: example.id, meeting: meeting, directory: directory, reportError: false)
        }
        var additions: [VoiceExample] = []
        for speaker in meeting.speakers where speaker.canAssignPerson && speaker.voiceReviewOrigin == nil {
            if examples.contains(where: {
                $0.meetingID == meeting.id && $0.speakerID == speaker.id && audioIsCurrent($0)
            }) {
                continue
            }
            let pending = examples.filter {
                $0.meetingID == meeting.id && $0.speakerID == speaker.id && $0.isPlayable && $0.audioRevision == nil
            }
            if !pending.isEmpty {
                for value in pending { guard hydratedExample(id: value.id) != nil else { return false } }
                var next = document
                for value in pending {
                    guard let index = next.examples.firstIndex(where: { $0.id == value.id }), let file = value.audioFile
                    else { continue }
                    next.examples[index].transcriptAssociation = nil
                    next.examples[index].audioRevision = Self.revision(url: directory.appendingPathComponent(file))
                }
                guard commit(next) else { return false }
                continue
            }
            let embedding = speaker.resolvedVoiceEmbedding.flatMap {
                SpeakerRecognition.isValid($0.values) ? $0 : nil
            }
            let sourceChanged =
                speaker.voiceSampleRange.map { range in
                    speaker.voiceSampleRevision.map {
                        Self.revision(url: directory.appendingPathComponent(range.audioFile)) != $0
                    } ?? false
                } ?? false
            let reference = VoiceExample(meetingID: meeting.id, speakerID: speaker.id, source: speaker.track)
            let resolved = sourceChanged ? nil : VoiceExampleResolution.resolve(reference, meeting: meeting)
            let range = sourceChanged ? nil : (speaker.voiceSampleRange ?? resolved?.range)
            guard range?.isValid == true || embedding != nil else { continue }
            let prior = examples.first { $0.meetingID == meeting.id && $0.speakerID == speaker.id }
            if range == nil, let embedding, let prior,
                hydratedExample(id: prior.id)?.embeddings.contains(embedding) == true
            {
                continue
            }
            additions.append(
                VoiceExample(
                    meetingID: meeting.id, speakerID: speaker.id, source: range?.source ?? speaker.track,
                    audioFile: range?.audioFile,
                    audioRevision: range.flatMap { Self.revision(url: directory.appendingPathComponent($0.audioFile)) },
                    start: range?.start, end: range?.end,
                    suggestedPersonID: speaker.personID ?? prior?.suggestedPersonID,
                    review: (speaker.personID ?? prior?.suggestedPersonID) == nil ? .unassigned : .suggested,
                    embeddings: embedding.map { [$0] } ?? [],
                    groupID: prior.flatMap { $0.manuallyGrouped ? $0.groupID : nil } ?? speaker.id,
                    origin: .savedSpeaker, firstPassage: resolved?.firstPassage, spans: range?.spans,
                    detectedSpeakerID: speaker.id.uuidString,
                    detectedSpeakerResultID: meeting.speakerLabelSource?.resultID,
                    detectedSpeakerSpans: meeting.transcript.filter { $0.speakerID == speaker.id && $0.end > $0.start }
                        .map { .init(start: $0.start, end: $0.end) }))
        }
        return upsert(additions)
    }

    @discardableResult
    func assign(
        meetingID: UUID, speakerID: UUID, personID: UUID?, staged: Bool = false,
        previousPersonID: UUID? = nil, exampleID: UUID? = nil,
        preservePreviousSpeakerDecision: Bool = true, updateReferenceEvidence: Bool = true,
        relatedExampleID: UUID? = nil
    ) -> Bool {
        guard admitVoiceWrite() else { return false }
        guard !canonicalCommitInFlight, pendingDocument == nil, readable, canWrite(), persistence != nil else {
            return false
        }
        var next = document
        var relatedIDs = Set<UUID>()
        if let relatedExampleID,
            let related = document.examples.first(where: {
                $0.id == relatedExampleID && $0.meetingID == meetingID
            })
        {
            relatedIDs.insert(related.id)
            if let key = VoiceExactReviewDecisions.Key(related) {
                relatedIDs.formUnion(exactExampleIDs[key] ?? [])
            }
        }
        var previousDecisions = document.decisions
        if exampleID == nil, preservePreviousSpeakerDecision,
            !previousDecisions.contains(where: { $0.meetingID == meetingID && $0.speakerID == speakerID })
        {
            previousDecisions.append(.init(meetingID: meetingID, speakerID: speakerID, personID: previousPersonID))
        }
        next.undo.append(
            .init(
                examples: document.examples.filter { example in
                    example.id == exampleID || relatedIDs.contains(example.id)
                        || (exampleID == nil && example.meetingID == meetingID && example.speakerID == speakerID)
                }.map(VoiceExampleReviewSnapshot.init), decisions: previousDecisions))
        next.undo = Array(next.undo.suffix(20))
        if exampleID == nil {
            next.decisions.removeAll { $0.meetingID == meetingID && $0.speakerID == speakerID }
            next.decisions.append(.init(meetingID: meetingID, speakerID: speakerID, personID: personID))
        }
        for index in next.examples.indices
        where next.examples[index].id == exampleID || relatedIDs.contains(next.examples[index].id)
            || (exampleID == nil && next.examples[index].meetingID == meetingID
                && next.examples[index].speakerID == speakerID)
        {
            if !updateReferenceEvidence {
                // Transcript identity and reference-audio review have separate
                // purposes. Keep explicit evidence and pending reviews intact.
                next.examples[index].transcriptAssociation = nil
                next.examples[index].suggestedPersonID = nil
                continue
            }
            if let rejected = next.examples[index].personID ?? next.examples[index].suggestedPersonID
                ?? next.examples[index].transcriptAssociation?.personID,
                rejected != personID, !next.examples[index].rejectedPersonIDs.contains(rejected)
            {
                next.examples[index].rejectedPersonIDs.append(rejected)
            }
            next.examples[index].transcriptAssociation = nil
            next.examples[index].personID = personID
            next.examples[index].namedPersonID = nil
            next.examples[index].suggestedPersonID = nil
            next.examples[index].review = personID == nil ? .rejected : .confirmed
            if let personID { next.examples[index].rejectedPersonIDs.removeAll { $0 == personID } }
        }
        if staged {
            pendingDocument = next
            return true
        }
        return commit(next, changed: [meetingID])
    }

    struct CanonicalCommit: Sendable {
        var previous: VoiceLibraryDocument
        var next: VoiceLibraryDocument
        var persistence: VoiceLibraryPersistence.Snapshot
    }
    private func admitVoiceWrite() -> Bool {
        guard isLoaded else {
            errorMessage = "The voice library is still opening. Wait for it to finish, then try again."
            return false
        }
        guard readable else { return false }
        guard !canonicalCommitInFlight, pendingDocument == nil else {
            errorMessage = "Voice changes are still saving. Wait for them to finish, then try again."
            return false
        }
        return true
    }
    func beginCanonicalCommit() throws -> CanonicalCommit? {
        guard let pendingDocument else { return nil }
        guard !canonicalCommitInFlight, let persistence else { throw ServiceError("The voice library is unavailable.") }
        canonicalCommitInFlight = true
        return CanonicalCommit(previous: document, next: pendingDocument, persistence: persistence.snapshot())
    }
    func finishCanonicalCommit(
        _ commit: CanonicalCommit?, state: VoiceLibraryPersistence.Snapshot?, committed: Bool,
        refreshFailed: Bool = false
    ) {
        guard let commit else { return }
        var affected = Set<UUID>()
        let reviewed = Self.reviewChangeMeetingIDs(previous: commit.previous, next: commit.next)
        defer {
            canonicalCommitInFlight = false
            pendingDocument = nil
            if committed { notifyProjectionChanges(affected: affected, reviewed: reviewed) }
        }
        if refreshFailed {
            readable = false
            errorMessage = "Couldn’t refresh the voice library after saving. Reopen the library before changing voices."
            unavailableError = errorMessage
        }
        else if let state {
            persistence?.adopt(state)
        }
        if committed {
            let changedRepresentations = commit.next.examples.contains { value in
                guard let index = exampleIndices[value.id] else { return !value.embeddings.isEmpty }
                return commit.previous.examples[index].embeddings != value.embeddings
            }
            document = commit.next
            if changedRepresentations { representationsRevision += 1 }
            affected = publish()
            hydratedIDs.formUnion(document.examples.filter { !$0.embeddings.isEmpty }.map(\.id))
            releaseRepresentations()
        }
    }

    private func updateProjectionEvidence(metadata: [VoiceExample]) -> Set<UUID> {
        let nextExamples = Dictionary(
            grouping: metadata.filter {
                $0.review == .confirmed || $0.transcriptAssociation != nil || !$0.rejectedPersonIDs.isEmpty
                    || $0.manuallyCleared
            }, by: \.meetingID)
        let nextEvidence = nextExamples.mapValues { $0.map(ProjectionEvidence.init) }
        let nextDecisions = Dictionary(grouping: document.decisions, by: \.meetingID)
        let ids = Set(projectionExamples.keys).union(nextExamples.keys)
            .union(projectionDecisions.keys).union(nextDecisions.keys)
        var affected = Set<UUID>()
        for id in ids where projectionEvidence[id] != nextEvidence[id] || projectionDecisions[id] != nextDecisions[id] {
            affected.insert(id)
            projectionRevisions[id, default: 0] += 1
            projectionCache[id] = nil
        }
        projectionExamples = nextExamples
        projectionEvidence = nextEvidence
        projectionAudioFiles = nextExamples.mapValues { Set($0.compactMap { $0.range?.audioFile }) }
        projectionDecisions = nextDecisions
        if deletedPeople != document.deletedPersonIDs {
            projectionDeletedPeopleRevision += 1
            projectionCache.removeAll()
            affected.formUnion(ids)
        }
        return affected
    }

    /// Paths from filesystem reconciliation include audio-only changes that do
    /// not alter the disposable meeting index or canonical meeting documents.
    @discardableResult
    func invalidateDecisionProjections(paths: [URL], root: URL, rebuild: Bool) -> Set<UUID> {
        let roots = Set([root.standardizedFileURL.path, LibraryFileMonitor.canonicalRoot(root).path])
        var ids = Set<UUID>()
        var all = rebuild
        for url in paths {
            let path = url.standardizedFileURL.path
            if roots.contains(path) {
                all = true
                break
            }
            guard let prefix = roots.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            let components = path.dropFirst(prefix.count + 1).split(separator: "/")
            guard components.first == "meetings" else { continue }
            guard components.count > 1 else {
                all = true
                break
            }
            guard let id = MeetingFolderLocation.identity(String(components[1])) else {
                // Top-level sidecars and unfinished imports do not affect saved
                // meetings. A deeper malformed path still requests recovery.
                if components.count == 2 { continue }
                all = true
                break
            }
            if components.count <= 2 {
                ids.insert(id)
            }
            else {
                let relative = components.dropFirst(2).joined(separator: "/")
                if projectionAudioFiles[id]?.contains(relative) == true {
                    ids.insert(id)
                }
            }
        }
        if all {
            ids.formUnion(projectionRevisions.keys)
            ids.formUnion(projectionCache.keys)
        }
        invalidateDecisionProjections(meetingIDs: ids)
        return ids
    }

    /// Filesystem reconciliation calls this when a meeting's audio may have changed.
    func invalidateDecisionProjections(meetingIDs: Set<UUID>) {
        for id in meetingIDs {
            projectionRevisions[id, default: 0] += 1
            projectionCache[id] = nil
        }
    }

    private func cachedProjection(for meeting: Meeting) -> Meeting? {
        guard let cached = projectionCache[meeting.id],
            cached.revision == projectionRevisions[meeting.id, default: 0],
            cached.deletedPeopleRevision == projectionDeletedPeopleRevision,
            cached.input == meeting || cached.output == meeting
        else { return nil }
        return cached.output
    }

    private func cacheProjection(_ output: Meeting, input: Meeting) {
        if projectionCache.count >= 16, projectionCache[input.id] == nil {
            projectionCache.removeValue(forKey: projectionCache.keys.first!)
        }
        projectionCache[input.id] = .init(
            input: input, output: output, revision: projectionRevisions[input.id, default: 0],
            deletedPeopleRevision: projectionDeletedPeopleRevision)
    }

    private func needsDecisionProjection(_ meeting: Meeting) -> Bool {
        projectionExamples[meeting.id] != nil || projectionDecisions[meeting.id] != nil
            || meeting.speakers.contains { $0.voiceReviewOrigin != nil }
    }

    var canProjectDecisions: Bool { isLoaded && readable }

    struct ProjectionToken: Equatable, Sendable {
        fileprivate let meetingID: UUID
        fileprivate let revision: Int
        fileprivate let deletedPeopleRevision: Int
    }
    struct DecisionProjection: Sendable {
        let meeting: Meeting
        let token: ProjectionToken
    }
    private func projectionToken(for id: UUID) -> ProjectionToken {
        .init(
            meetingID: id, revision: projectionRevisions[id, default: 0],
            deletedPeopleRevision: projectionDeletedPeopleRevision)
    }
    /// Correctness depends on evidence generations, independently of cache eviction.
    func isCurrentDecisionProjection(_ token: ProjectionToken) -> Bool {
        canProjectDecisions && projectionToken(for: token.meetingID) == token
    }

    func adoptCommittedProjection(_ projection: DecisionProjection, canonical: Meeting) {
        guard canonical.id == projection.meeting.id, isCurrentDecisionProjection(projection.token) else { return }
        // Canonical save allocates speaker colors. Keep that equivalent output
        // as the cache input so a cold-load follow-up does not scan audio twice.
        cacheProjection(canonical, input: canonical)
    }

    /// Synchronous compatibility for callers that already own a canonical mutation.
    /// Derived refreshes use projectedDecisions so transcript work runs on a worker.
    func applyingDecisions(to meeting: Meeting) -> Meeting {
        guard isLoaded, readable else { return meeting }
        if let cached = cachedProjection(for: meeting) { return cached }
        guard needsDecisionProjection(meeting) else { return meeting }
        let evidence = VoiceDecisionProjection.currentEvidence(
            projectionExamples[meeting.id] ?? [], directory: url.deletingLastPathComponent())
        projectionComputationCount += 1
        let output = VoiceDecisionProjection.apply(
            to: meeting, evidence: evidence, decisions: projectionDecisions[meeting.id] ?? [],
            deletedPeople: Set(deletedPeople), policy: latestSuggestionPolicy)
        cacheProjection(output, input: meeting)
        return output
    }

    /// Compatibility for consumers that only need the computed meeting value.
    func projectedDecisions(to meeting: Meeting) async -> Meeting? {
        guard canProjectDecisions else { return meeting }
        return await decisionProjection(to: meeting)?.meeting
    }

    /// A nil result means this input was cancelled, unavailable, or superseded.
    /// Committers validate the token and their current meeting in the write lane.
    func decisionProjection(to meeting: Meeting) async -> DecisionProjection? {
        guard canProjectDecisions, !Task.isCancelled else { return nil }
        let token = projectionToken(for: meeting.id)
        if let cached = cachedProjection(for: meeting) { return .init(meeting: cached, token: token) }
        guard needsDecisionProjection(meeting) else { return .init(meeting: meeting, token: token) }
        let evidence = projectionExamples[meeting.id] ?? []
        let decisions = projectionDecisions[meeting.id] ?? []
        let deleted = Set(deletedPeople)
        let directory = url.deletingLastPathComponent()
        let beforeRead = beforeProjectionRead
        let policy = latestSuggestionPolicy
        projectionComputationCount += 1
        let output = await Task.detached(priority: .utility) {
            beforeRead?()
            let current = VoiceDecisionProjection.currentEvidence(evidence, directory: directory)
            return VoiceDecisionProjection.apply(
                to: meeting, evidence: current, decisions: decisions, deletedPeople: deleted, policy: policy)
        }.value
        guard !Task.isCancelled, isCurrentDecisionProjection(token) else { return nil }
        cacheProjection(output, input: meeting)
        return .init(meeting: output, token: token)
    }

    @discardableResult
    func mergePerson(id: UUID, into targetID: UUID, staged: Bool = false) -> Bool {
        mergePeople(ids: [id], into: targetID, staged: staged)
    }

    @discardableResult
    func mergePeople(ids: Set<UUID>, into targetID: UUID, staged: Bool = false) -> Bool {
        guard admitVoiceWrite() else { return false }
        guard !canonicalCommitInFlight, pendingDocument == nil, !ids.isEmpty, !ids.contains(targetID), readable,
            canWrite(), persistence != nil,
            !document.deletedPersonIDs.contains(targetID)
        else { return false }
        var next = document
        next.deletedPersonIDs += ids.subtracting(next.deletedPersonIDs).sorted { $0.uuidString < $1.uuidString }
        for index in next.examples.indices {
            if next.examples[index].transcriptAssociation.map({ ids.contains($0.personID) }) == true {
                next.examples[index].transcriptAssociation = nil
            }
            if next.examples[index].personID.map(ids.contains) == true { next.examples[index].personID = targetID }
            if next.examples[index].namedPersonID.map(ids.contains) == true {
                next.examples[index].namedPersonID = targetID
            }
            if next.examples[index].suggestedPersonID.map(ids.contains) == true {
                next.examples[index].suggestedPersonID = targetID
            }
            next.examples[index].rejectedPersonIDs = PersonMerge(sourceIDs: ids, targetID: targetID)
                .replacing(next.examples[index].rejectedPersonIDs)
            if next.examples[index].personID == targetID {
                next.examples[index].rejectedPersonIDs.removeAll { $0 == targetID }
            }
            if next.examples[index].rejectedPersonIDs.contains(targetID),
                next.examples[index].suggestedPersonID == targetID
            {
                next.examples[index].suggestedPersonID = nil
                if next.examples[index].namedPersonID == targetID { next.examples[index].namedPersonID = nil }
                if next.examples[index].review == .suggested { next.examples[index].review = .rejected }
            }
        }
        for index in next.decisions.indices where next.decisions[index].personID.map(ids.contains) == true {
            next.decisions[index].personID = targetID
        }
        // Review undo must not restore the removed directory identity.
        next.undo.removeAll()
        if staged {
            pendingDocument = next
            return true
        }
        return commit(next)
    }

    @discardableResult
    func removePerson(id: UUID, staged: Bool = false) -> Bool {
        guard admitVoiceWrite() else { return false }
        guard !canonicalCommitInFlight, pendingDocument == nil, readable, canWrite(), persistence != nil else {
            return false
        }
        var next = document
        if !next.deletedPersonIDs.contains(id) { next.deletedPersonIDs.append(id) }
        for index in next.examples.indices {
            if next.examples[index].transcriptAssociation?.personID == id {
                next.examples[index].transcriptAssociation = nil
            }
            if next.examples[index].personID == id {
                next.examples[index].personID = nil
                next.examples[index].review = .unassigned
            }
            if next.examples[index].suggestedPersonID == id { next.examples[index].suggestedPersonID = nil }
            if next.examples[index].namedPersonID == id { next.examples[index].namedPersonID = nil }
            next.examples[index].rejectedPersonIDs.removeAll { $0 == id }
        }
        for index in next.decisions.indices where next.decisions[index].personID == id {
            next.decisions[index].personID = nil
        }
        // A deleted contact cannot be resurrected through voice-review undo.
        next.undo.removeAll()
        if staged {
            pendingDocument = next
            return true
        }
        return commit(next)
    }
}
