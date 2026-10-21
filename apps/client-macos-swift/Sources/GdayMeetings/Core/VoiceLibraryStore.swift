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
    private var reviewSnapshots: [Set<UUID>: VoiceReviewSnapshot] = [:]
    private var readable = true
    private var unavailableError: String?
    private var pendingDocument: VoiceLibraryDocument?
    private var canonicalCommitInFlight = false
    private struct ProjectionCacheEntry {
        var input: Meeting
        var output: Meeting
        var evidenceIDs: Set<UUID>
    }
    private var projectionCache: [UUID: ProjectionCacheEntry] = [:]
    private var deletedPeople: [UUID] = []
    var didChange: ((Set<UUID>) -> Void)?

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

    private func publish() {
        let metadata = document.examples.map { example in
            var value = example
            value.embeddings = []
            return value
        }
        if examples != metadata || decisions != document.decisions || deletedPeople != document.deletedPersonIDs {
            projectionCache.removeAll()
        }
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
    }

    private func commit(_ next: VoiceLibraryDocument, changed: Set<UUID> = []) -> Bool {
        guard admitVoiceWrite() else { return false }
        guard !canonicalCommitInFlight, pendingDocument == nil, readable, canWrite(), let persistence else {
            errorMessage = "The voice library is read-only. Check the data folder before saving changes."
            return false
        }
        do {
            try persistence.commit(previous: document, next: next)
            publishCommittedVoiceDocument(next, warning: persistence.maintenanceWarning)
            if !changed.isEmpty { didChange?(changed) }
            return true
        }
        catch {
            errorMessage = "Couldn’t save the voice library. \(error.localizedDescription)"
            return false
        }
    }

    private func publishCommittedVoiceDocument(_ next: VoiceLibraryDocument, warning: String?) {
        let changedRepresentations = next.examples.contains { value in
            guard let index = exampleIndices[value.id] else {
                return !value.embeddings.isEmpty
            }
            return document.examples[index].embeddings != value.embeddings
        }
        document = next
        if changedRepresentations { representationsRevision += 1 }
        errorMessage = warning
        publish()
        hydratedIDs.formUnion(
            document.examples.filter { !$0.embeddings.isEmpty }.map(\.id))
        releaseRepresentations()
    }

    @discardableResult
    func upsert(_ incoming: [VoiceExample], staged: Bool = false) -> Bool {
        if staged, !admitVoiceWrite() { return false }
        for value in incoming where !value.embeddings.isEmpty {
            if document.examples.contains(where: { $0.id == value.id }), hydratedExample(id: value.id) == nil {
                return false
            }
        }
        var next = document
        for value in incoming {
            if let index = next.examples.firstIndex(where: { $0.id == value.id }) {
                // Preparation may finish after review. Only representations
                // can change; a stale task cannot overwrite identity decisions.
                guard next.examples[index].range == value.range else { continue }
                for embedding in value.embeddings where embedding.isValid {
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
    func reject(ids: Set<UUID>, personID: UUID) -> Bool {
        edit(ids: exactReviewIDs(ids)) {
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
        try await reviewSnapshot(for: [personID]).candidates[personID] ?? []
    }

    func reviewCandidates(for personIDs: Set<UUID>) async throws -> [UUID: [VoiceExample]] {
        try await reviewSnapshot(for: personIDs).candidates
    }

    /// Counts and dialogs use these exact queues. Refresh also checks recording
    /// files changed outside the library, such as a moved or replaced recording.
    func reviewSnapshot(for personIDs: Set<UUID>, forceRefresh: Bool = false) async throws -> VoiceReviewSnapshot {
        if forceRefresh { invalidateReviewAudio() }
        reviewSnapshotReaders += 1
        defer { reviewSnapshotReaders -= 1 }
        while true {
            let evidence = try await readReviewEvidence()
            try Task.checkCancellation()
            let activePeople = personIDs.subtracting(deletedPeople)
            if let cached = reviewSnapshots[activePeople] { return cached }
            let revision = reviewEvidenceRevision
            let result = await Task.detached(priority: .utility) {
                VoiceReviewSnapshot.make(
                    hydrated: evidence.hydrated, metadata: evidence.metadata,
                    playableIDs: evidence.playableIDs, personIDs: activePeople, revision: revision)
            }.value
            try Task.checkCancellation()
            guard revision == reviewEvidenceRevision, reviewEvidence != nil else { continue }
            reviewSnapshots[activePeople] = result
            return result
        }
    }

    /// Compatibility for workflows that inspect all stored groups. Ineligible
    /// members remain linked evidence and never become playback questions.
    func identificationGroups() async throws -> [VoiceIdentificationGroup] {
        let evidence = try await readReviewEvidence()
        return VoiceReviewSnapshot.groups(
            hydrated: evidence.hydrated, metadata: evidence.metadata,
            playableIDs: evidence.playableIDs)
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

    private func matchingResult(from people: [Person], includeSuggestions: Bool) async throws
        -> VoiceMatchingWorker.Output
    {
        try Task.checkCancellation()
        guard readable, isLoaded, !canonicalCommitInFlight, pendingDocument == nil, let persistence else {
            throw ServiceError("The voice library is unavailable for matching.")
        }
        let snapshot = persistence.snapshot()
        let input = VoiceMatchingWorker.Input(
            directory: url.deletingLastPathComponent(), persistence: snapshot, examples: examples,
            people: people, deletedPeople: deletedPeople, includeSuggestions: includeSuggestions)
        for mode in Array(matchingOperations.keys) {
            guard let operation = matchingOperations[mode] else { continue }
            if operation.input.persistence.revision != snapshot.revision
                || operation.input.persistence.fileRevisions != snapshot.fileRevisions
                || operation.input.people != people
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
            examples == input.examples, deletedPeople == input.deletedPeople
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

    func suggestReviewedPeople(from people: [Person]) async {
        do { try await suggestReviewedPeopleResult(from: people) }
        catch is CancellationError {}
        catch {
            errorMessage = "Couldn’t prepare voice matches. \(error.localizedDescription)"
        }
    }

    func suggestReviewedPeopleResult(from people: [Person]) async throws {
        let result = try await matchingResult(from: people, includeSuggestions: true)
        try Task.checkCancellation()
        var next = document
        for suggestion in result.suggestions {
            guard let index = exampleIndices[suggestion.exampleID], next.examples[index].acceptsSuggestions else {
                continue
            }
            let personID = next.examples[index].namedPersonID ?? suggestion.personID
            next.examples[index].suggestedPersonID = personID
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
        guard next.examples[index].suggestedPersonID != candidate else { return true }
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
                    origin: .savedSpeaker, firstPassage: resolved?.firstPassage, spans: range?.spans))
        }
        return upsert(additions)
    }

    @discardableResult
    func assign(
        meetingID: UUID, speakerID: UUID, personID: UUID?, staged: Bool = false,
        previousPersonID: UUID? = nil, exampleID: UUID? = nil
    ) -> Bool {
        guard admitVoiceWrite() else { return false }
        guard !canonicalCommitInFlight, pendingDocument == nil, readable, canWrite(), persistence != nil else {
            return false
        }
        var next = document
        var previousDecisions = document.decisions
        if exampleID == nil,
            !previousDecisions.contains(where: { $0.meetingID == meetingID && $0.speakerID == speakerID })
        {
            previousDecisions.append(.init(meetingID: meetingID, speakerID: speakerID, personID: previousPersonID))
        }
        next.undo.append(
            .init(
                examples: document.examples.filter { example in
                    example.id == exampleID
                        || (exampleID == nil && example.meetingID == meetingID && example.speakerID == speakerID)
                }.map(VoiceExampleReviewSnapshot.init), decisions: previousDecisions))
        next.undo = Array(next.undo.suffix(20))
        if exampleID == nil {
            next.decisions.removeAll { $0.meetingID == meetingID && $0.speakerID == speakerID }
            next.decisions.append(.init(meetingID: meetingID, speakerID: speakerID, personID: personID))
        }
        for index in next.examples.indices
        where next.examples[index].id == exampleID
            || (exampleID == nil && next.examples[index].meetingID == meetingID
                && next.examples[index].speakerID == speakerID)
        {
            if let rejected = next.examples[index].personID ?? next.examples[index].suggestedPersonID,
                rejected != personID, !next.examples[index].rejectedPersonIDs.contains(rejected)
            {
                next.examples[index].rejectedPersonIDs.append(rejected)
            }
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
        defer {
            canonicalCommitInFlight = false
            pendingDocument = nil
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
            publish()
            hydratedIDs.formUnion(document.examples.filter { !$0.embeddings.isEmpty }.map(\.id))
            releaseRepresentations()
        }
    }

    func applyingDecisions(to meeting: Meeting) -> Meeting {
        guard isLoaded, readable else { return meeting }
        var updated = meeting
        guard
            decisions.contains(where: { $0.meetingID == meeting.id })
                || examples.contains(where: {
                    $0.meetingID == meeting.id && ($0.isReviewed || !$0.rejectedPersonIDs.isEmpty)
                })
                || meeting.speakers.contains(where: { $0.voiceReviewOrigin != nil })
        else { return meeting }
        let evidence = examples.filter {
            $0.meetingID == meeting.id
                && ($0.review == .confirmed || !$0.rejectedPersonIDs.isEmpty
                    || $0.manuallyCleared)
                && audioIsCurrent($0)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let evidenceIDs = Set(evidence.map(\.id))
        if let cached = projectionCache[meeting.id], cached.evidenceIDs == evidenceIDs,
            cached.input == meeting || cached.output == meeting
        {
            return cached.output
        }
        let projections = updated.speakers.filter { $0.voiceReviewOrigin != nil }
        if evidence.isEmpty, projections.isEmpty, !decisions.contains(where: { $0.meetingID == meeting.id }) {
            return meeting
        }
        updated.speakers.removeAll { $0.voiceReviewOrigin != nil }
        for projection in projections {
            guard let origin = projection.voiceReviewOrigin else { continue }
            var restored = projection
            restored.id = origin.speakerID
            restored.personID = origin.personID
            restored.manuallyAssigned = origin.manuallyAssigned
            restored.manualReviewThrough = origin.manualReviewThrough
            restored.confidence = origin.confidence
            restored.voiceReviewOrigin = nil
            restored.voiceReviewExampleID = nil
            if !updated.speakers.contains(where: { $0.id == restored.id }) { updated.speakers.append(restored) }
            for index in updated.transcript.indices where updated.transcript[index].speakerID == projection.id {
                updated.transcript[index].speakerID = origin.speakerID
            }
        }
        for decision in decisions where decision.meetingID == meeting.id {
            guard let index = updated.speakers.firstIndex(where: { $0.id == decision.speakerID }) else { continue }
            updated.speakers[index].personID = decision.personID
            updated.speakers[index].manuallyAssigned = true
            updated.speakers[index].confidence = nil
        }
        for index in updated.speakers.indices {
            if let personID = updated.speakers[index].personID, document.deletedPersonIDs.contains(personID) {
                updated.speakers[index].personID = nil
            }
        }
        let originalUsed = Set(updated.transcript.compactMap(\.speakerID))
        for index in updated.transcript.indices {
            let row = updated.transcript[index]
            guard row.end > row.start,
                let speaker = updated.speakers.first(where: { $0.id == row.speakerID })
            else { continue }
            let file: String?
            if let source = row.source {
                let candidates = updated.audioFiles.filter {
                    LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == source.rawValue
                }
                file = candidates.count == 1 ? candidates.first : nil
            }
            else if speaker.track.hasPrefix("track"), let track = Int(speaker.track.dropFirst(5)),
                updated.audioFiles.indices.contains(track)
            {
                file = updated.audioFiles[track]
            }
            else if updated.audioFiles.count == 1 {
                file = updated.audioFiles.first
            }
            else {
                let candidates = updated.audioFiles.filter {
                    let source = LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0))
                    return source == speaker.track || (source == "microphone" && speaker.track == "mic")
                        || (source == "system" && speaker.track == "system_mix")
                }
                file = candidates.count == 1 ? candidates.first : nil
            }
            let relevant = evidence.filter {
                guard let range = $0.range else { return false }
                let applies =
                    $0.review == .confirmed || $0.manuallyCleared
                    || speaker.personID.map($0.rejectedPersonIDs.contains) == true
                return applies && range.audioFile == file && range.contains(start: row.start, end: row.end)
            }
            guard let first = relevant.first(where: { $0.review == .confirmed }) ?? relevant.first else { continue }
            let confirmedPeople = Set(relevant.filter { $0.review == .confirmed }.map(\.personID))
            var people: Set<UUID?> = confirmedPeople.isEmpty ? [nil] : confirmedPeople
            // A negative answer about one person cannot contradict positive
            // evidence for somebody else covering the same passage.
            if relevant.contains(where: { example in
                confirmedPeople.contains { person in
                    person.map(example.rejectedPersonIDs.contains) == true
                }
            }) {
                people.insert(nil)
            }
            // Reviewing examples during a whole-label assignment confirms that
            // same decision; it does not create a distinct voice for each passage.
            // Conflicting or different exact-time reviews still need a projection.
            if speaker.manuallyAssigned == true, people.count == 1, people.first! == speaker.personID {
                continue
            }
            var assigned = speaker
            assigned.id = VoiceProjectionOrigin.identity(exampleID: first.id, segmentID: row.id)
            // Saving allocates colors for distinct projected voices. Preserve
            // that passage's saved slot when rebuilding its projection, rather
            // than copying the first restored origin's slot onto every voice.
            // Otherwise reading the meeting repeatedly undoes save's allocation.
            if let prior = meeting.speakers.first(where: { $0.id == assigned.id }) {
                assigned.colorSlot = prior.colorSlot
            }
            assigned.voiceReviewOrigin = .init(
                speakerID: speaker.id, personID: speaker.personID,
                manuallyAssigned: speaker.manuallyAssigned, confidence: speaker.confidence,
                manualReviewThrough: speaker.manualReviewThrough)
            assigned.voiceReviewExampleID = first.id
            assigned.personID = people.count == 1 ? people.first! : nil
            assigned.manuallyAssigned = true
            assigned.manualReviewThrough = nil
            assigned.confidence = nil
            if !updated.speakers.contains(where: { $0.id == assigned.id }) { updated.speakers.append(assigned) }
            updated.transcript[index].speakerID = assigned.id
        }
        let used = Set(updated.transcript.compactMap(\.speakerID))
        updated.speakers.removeAll { originalUsed.contains($0.id) && !used.contains($0.id) }
        let priorPeople = Set(meeting.speakers.compactMap(\.personID))
        updated.personIDs.removeAll { priorPeople.contains($0) }
        updated.replaceSpeakers(updated.speakers)
        // Folder metadata stores associations in canonical order. Projection
        // must use the same order so a disk reload cannot trigger another save.
        updated.personIDs = MeetingListEntry(updated).personIDs
        if projectionCache.count >= 16 { projectionCache.removeAll() }
        projectionCache[meeting.id] = .init(input: meeting, output: updated, evidenceIDs: evidenceIDs)
        return updated
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
