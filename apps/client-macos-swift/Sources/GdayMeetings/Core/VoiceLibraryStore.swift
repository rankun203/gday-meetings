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
            recordings[recording, default: []].append(
                .init(id: example.id, personID: example.personID, start: range.start, end: range.end))
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
    @Published private(set) var jobs: [VoicePreparationJob] = []
    @Published private(set) var isLoaded = false
    private(set) var decisions: [VoiceSpeakerDecision] = []
    private var document = VoiceLibraryDocument()
    private var scheduledSuggestions: Task<Void, Never>?
    private struct ObservationSelection: Equatable {
        var id: UUID
        var observationID: String?
        var speakerID: UUID
        var groupID: UUID
        var range: VoiceSampleRange?
        var embeddings: [TypedVoiceEmbedding]
        init(_ value: VoiceExample) {
            id = value.id
            observationID = value.observationID
            speakerID = value.speakerID
            groupID = value.groupID
            range = value.range
            embeddings = value.embeddings
        }
    }
    private var lastObservationSelection: (meetingID: UUID, revision: Int, values: [ObservationSelection])?
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
    @Published private(set) var representationsRevision = 0
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
        deletedPeople = document.deletedPersonIDs
        if examples != metadata {
            examples = metadata
            exampleIndices = Dictionary(uniqueKeysWithValues: metadata.enumerated().map { ($0.element.id, $0.offset) })
            personExampleIDs = [:]
            for example in metadata {
                for personID in [example.personID, example.suggestedPersonID].compactMap({ $0 }) {
                    personExampleIDs[personID, default: []].insert(example.id)
                }
            }
            hydratedIDs.formIntersection(exampleIndices.keys)
        }
        if decisions != document.decisions { decisions = document.decisions }
        canUndo = !document.undo.isEmpty
        if jobs != document.jobs { jobs = document.jobs }
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

    /// New capture evidence supersedes older suggestions without blocking the
    /// live identity actor on profile matching. The worker validates revisions.
    func scheduleReviewedPeopleSuggestions(from people: [Person]) {
        scheduledSuggestions?.cancel()
        scheduledSuggestions = Task { [weak self] in
            await self?.suggestReviewedPeople(from: people)
        }
    }

    /// Replace the current unreviewed representative selection atomically. Human
    /// reviews remain attached to their exact audio even when clustering changes.
    private func observationReconciliation(meetingID: UUID, representatives: [VoiceExample])
        -> (next: VoiceLibraryDocument, selection: [ObservationSelection])?
    {
        guard admitVoiceWrite(), canWrite(), persistence != nil else { return nil }
        guard
            representatives.allSatisfy({
                $0.meetingID == meetingID && $0.observationID?.isEmpty == false && $0.range != nil
                    && !$0.isReviewed && !$0.manuallyGrouped && $0.personID == nil
                    && !$0.embeddings.isEmpty && $0.embeddings.allSatisfy(\.isValid)
            }), Set(representatives.map(\.id)).count == representatives.count
        else { return nil }
        let selection = representatives.map(ObservationSelection.init).sorted { $0.id.uuidString < $1.id.uuidString }
        if let previous = lastObservationSelection, previous.meetingID == meetingID,
            previous.revision == representationsRevision, previous.values == selection,
            representatives.allSatisfy({ exampleIndices[$0.id] != nil })
        {
            return (document, selection)
        }
        // Hydrate only reused representatives. Unrelated library vectors stay on disk.
        for value in representatives where exampleIndices[value.id] != nil {
            guard hydratedExample(id: value.id) != nil else { return nil }
        }
        let desired = Dictionary(uniqueKeysWithValues: representatives.map { ($0.id, $0) })
        var next = document
        for value in representatives {
            guard let index = exampleIndices[value.id] else { continue }
            let old = next.examples[index]
            guard old.meetingID == meetingID, old.observationID == value.observationID,
                old.range == value.range
            else { return nil }
        }
        let undoEvidence = Set(next.undo.flatMap { $0.examples.map(\.id) })
        next.examples.removeAll {
            $0.meetingID == meetingID && $0.observationID != nil && desired[$0.id] == nil
                && !$0.isReviewed && !$0.manuallyGrouped && !undoEvidence.contains($0.id)
        }
        let retainedIndices = Dictionary(
            uniqueKeysWithValues: next.examples.enumerated().map { ($0.element.id, $0.offset) })
        for value in representatives {
            if let index = retainedIndices[value.id] {
                let old = next.examples[index]
                // A confirmed voice, explicit rejection/removal, or user grouping
                // cannot be undone by a delayed clustering callback.
                guard !old.isReviewed && !old.manuallyGrouped else { continue }
                if old.speakerID != value.speakerID || old.groupID != value.groupID {
                    next.examples[index].speakerID = value.speakerID
                    next.examples[index].groupID = value.groupID
                    next.examples[index].suggestedPersonID = nil
                    next.examples[index].review = .unassigned
                }
                next.examples[index].embeddings = value.embeddings
            }
            else {
                next.examples.append(value)
            }
        }
        return (next, selection)
    }

    @discardableResult
    func reconcileObservationExamples(meetingID: UUID, representatives: [VoiceExample]) -> Bool {
        guard let plan = observationReconciliation(meetingID: meetingID, representatives: representatives),
            plan.next.examples == document.examples || commit(plan.next)
        else { return false }
        lastObservationSelection = (meetingID, representationsRevision, plan.selection)
        return true
    }

    /// Prepare the library-wide diff away from the UI actor. Human reviews stay
    /// available while preparation runs; a changed revision rebuilds the plan.
    func reconcileObservationExamplesForCapture(meetingID: UUID, representatives: [VoiceExample]) async -> Bool {
        while !Task.isCancelled {
            guard let plan = observationReconciliation(meetingID: meetingID, representatives: representatives),
                let persistence
            else { return false }
            if plan.next.examples == document.examples {
                lastObservationSelection = (meetingID, representationsRevision, plan.selection)
                return true
            }
            let previous = document
            let snapshot = persistence.snapshot()
            let directory = url.deletingLastPathComponent()
            let beforePreparation = beforeObservationPreparation
            let preparation = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                try beforePreparation?()
                let backend = try VoiceLibraryPersistence(directory: directory, writable: false)
                backend.adopt(snapshot)
                let result = try backend.prepare(previous: previous, next: plan.next)
                try Task.checkCancellation()
                return result
            }
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                guard persistence.snapshot().revision == snapshot.revision else { continue }
                guard admitVoiceWrite(), canWrite() else { return false }
                try persistence.commit(prepared)
                publishCommittedVoiceDocument(plan.next, warning: persistence.maintenanceWarning)
                lastObservationSelection = (meetingID, representationsRevision, plan.selection)
                return true
            }
            catch is CancellationError {
                return false
            }
            catch {
                errorMessage = "Couldn’t save speaker review examples. \(error.localizedDescription)"
                return false
            }
        }
        return false
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

    @discardableResult
    func confirm(ids: Set<UUID>, personID: UUID) -> Bool {
        guard !document.deletedPersonIDs.contains(personID) else { return false }
        return edit(ids: ids) {
            $0.personID = personID
            $0.suggestedPersonID = nil
            $0.review = .confirmed
            $0.rejectedPersonIDs.removeAll { $0 == personID }
            $0.excluded = false
            $0.manuallyCleared = false
        }
    }

    @discardableResult
    func reject(ids: Set<UUID>, personID: UUID) -> Bool {
        edit(ids: ids) {
            if !$0.rejectedPersonIDs.contains(personID) { $0.rejectedPersonIDs.append(personID) }
            if $0.personID == personID { $0.personID = nil }
            if $0.suggestedPersonID == personID { $0.suggestedPersonID = nil }
            $0.review = $0.personID == nil ? .rejected : .confirmed
        }
    }

    @discardableResult
    func clear(ids: Set<UUID>) -> Bool {
        edit(ids: ids) {
            $0.personID = nil
            $0.suggestedPersonID = nil
            $0.review = .unassigned
            $0.manuallyCleared = true
        }
    }

    @discardableResult
    func exclude(ids: Set<UUID>, excluded: Bool = true) -> Bool {
        edit(ids: ids) { $0.excluded = excluded }
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

    @discardableResult
    func setJobs(_ jobs: [VoicePreparationJob]) -> Bool {
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
            self.jobs = jobs
            errorMessage = persistence.maintenanceWarning
            return true
        }
        catch {
            errorMessage = "Couldn’t save voice preparation progress. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func undo() -> Bool {
        guard let previous = document.undo.last else { return false }
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
        return commit(next, changed: changedMeetings)
    }

    /// Confirmed samples are usable with the model that produced them, even
    /// when their source recording is unavailable for playback.
    func matchingPeople(from people: [Person]) async throws -> [Person] {
        try await matchingResult(from: people, includeSuggestions: false).profiles
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
            return otherRange.audioFile == range.audioFile && otherRange.start < range.end
                && otherRange.end > range.start
        }
    }

    /// File identity and modification metadata invalidate replacement and edits
    /// without rereading hours of audio on the UI actor.
    nonisolated static func revision(url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber,
            let modified = attributes[.modificationDate] as? Date
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
                next.examples[index].source = range.source
                next.examples[index].speakerID = resolved.speakerID
            }
        }
        let changed: Set<UUID> = example.review == .rejected || example.manuallyCleared ? [meeting.id] : []
        guard next.examples == document.examples || commit(next, changed: changed) else { return nil }
        return hydratedExample(id: exampleID)
    }

    func suggestReviewedPeople(from people: [Person]) async {
        do {
            let result = try await matchingResult(from: people, includeSuggestions: true)
            try Task.checkCancellation()
            var next = document
            for suggestion in result.suggestions {
                guard let index = exampleIndices[suggestion.exampleID], !next.examples[index].isReviewed else {
                    continue
                }
                next.examples[index].suggestedPersonID = suggestion.personID
                next.examples[index].review = suggestion.personID == nil ? .unassigned : .suggested
            }
            if next.examples != document.examples { _ = commit(next) }
        }
        catch is CancellationError {}
        catch {
            errorMessage = "Couldn’t prepare voice matches. \(error.localizedDescription)"
        }
    }

    /// Rejections are evidence, not global person bans. Exact reviewed audio is
    /// authoritative; novel voices remain suggestions until explicitly reviewed.
    func rejectedPeople(meetingID: UUID, speakerID: UUID) -> Set<UUID> {
        Set(examples.filter { $0.meetingID == meetingID && $0.speakerID == speakerID }.flatMap(\.rejectedPersonIDs))
    }

    @discardableResult
    func suggest(exampleID: UUID, personID: UUID?) -> Bool {
        defer { releaseRepresentations() }
        guard let index = document.examples.firstIndex(where: { $0.id == exampleID }),
            !document.examples[index].isReviewed
        else { return true }
        let candidate = allowedSuggestion(for: document.examples[index], personID: personID)
        var next = document
        guard next.examples[index].suggestedPersonID != candidate else { return true }
        next.examples[index].suggestedPersonID = candidate
        next.examples[index].review = candidate == nil ? .unassigned : .suggested
        return commit(next)
    }

    private func allowedSuggestion(for example: VoiceExample, personID: UUID?) -> UUID? {
        guard let personID else { return nil }
        let candidate: VoiceExample
        if exampleIndices[example.id] != nil {
            guard let hydrated = hydratedExample(id: example.id) else { return nil }
            candidate = hydrated
        }
        else {
            candidate = example
        }
        let rejectedMetadata = examples.filter { $0.rejectedPersonIDs.contains(personID) }
        let rejectedExamples = hydratedExamples(ids: Set(rejectedMetadata.map(\.id)))
        guard rejectedExamples.count == rejectedMetadata.count else { return nil }
        do {
            if document.deletedPersonIDs.contains(personID) || candidate.rejectedPersonIDs.contains(personID)
                || candidate.voiceEmbeddings.contains(where: { embedding in
                    rejectedExamples.contains { rejected in
                        rejected.rejectedPersonIDs.contains(personID)
                            && rejected.voiceEmbeddings.contains {
                                $0.type == embedding.type && $0.isValid && embedding.isValid
                                    && (SpeakerRecognition.similarity($0.values, embedding.values) ?? -1)
                                        >= SpeakerRecognition.threshold
                            }
                    }
                })
            {
                return nil
            }
        }
        return personID
    }

    @discardableResult
    func ingest(meeting: Meeting, directory: URL, finalizeLive: Bool = false) -> Bool {
        for example in examples
        where example.meetingID == meeting.id && example.range == nil {
            _ = resolveLegacyExample(exampleID: example.id, meeting: meeting, directory: directory, reportError: false)
        }
        // Finalize every retained live example, including reviewed evidence for a
        // retired cluster that no longer appears in the transcript's speaker list.
        if finalizeLive {
            let pending = examples.filter {
                $0.meetingID == meeting.id && $0.origin == .liveSpeech
                    && $0.isPlayable && $0.audioRevision == nil
            }
            for example in pending { guard hydratedExample(id: example.id) != nil else { return false } }
            var next = document
            for example in pending {
                guard let index = next.examples.firstIndex(where: { $0.id == example.id }),
                    let original = example.audioFile
                else { continue }
                let candidates =
                    meeting.audioFiles.contains(original)
                    ? [original]
                    : meeting.audioFiles.filter {
                        LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == example.source
                    }
                guard candidates.count == 1, let file = candidates.first,
                    let revision = Self.revision(url: directory.appendingPathComponent(file))
                else { continue }
                next.examples[index].audioFile = file
                next.examples[index].audioRevision = revision
            }
            if next != document, !commit(next) { return false }
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
                    guard let index = next.examples.firstIndex(where: { $0.id == value.id }), var file = value.audioFile
                    else { continue }
                    if finalizeLive, !meeting.audioFiles.contains(file) {
                        let candidates = meeting.audioFiles.filter {
                            LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == value.source
                        }
                        if candidates.count == 1 {
                            file = candidates[0]
                            next.examples[index].audioFile = file
                        }
                    }
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
                    embeddings: embedding.map { [$0] } ?? [], groupID: prior?.groupID ?? UUID(),
                    origin: .savedSpeaker, firstPassage: resolved?.firstPassage))
        }
        return upsert(additions)
    }

    /// Capture keeps a few independent excerpts, not every inference window.
    /// New evidence never inherits human confirmation from an earlier excerpt.
    @discardableResult
    func recordSample(
        meetingID: UUID, speakerID: UUID, range: VoiceSampleRange,
        embedding: TypedVoiceEmbedding, suggestion: UUID?
    ) -> Bool {
        guard range.isValid, embedding.isValid else { return false }
        let existing = examples.filter { $0.meetingID == meetingID && $0.speakerID == speakerID && $0.isPlayable }
        guard existing.count < 3 else { return true }
        guard
            !existing.contains(where: {
                $0.audioFile == range.audioFile && ($0.start ?? 0) < range.end && ($0.end ?? 0) > range.start
            })
        else { return true }
        let rejected = rejectedPeople(meetingID: meetingID, speakerID: speakerID)
        let suggestion = suggestion.flatMap { rejected.contains($0) ? nil : $0 }
        var example = VoiceExample(
            meetingID: meetingID, speakerID: speakerID, source: range.source,
            audioFile: range.audioFile, start: range.start, end: range.end,
            suggestedPersonID: suggestion, review: suggestion == nil ? .unassigned : .suggested,
            embeddings: [embedding], groupID: existing.first?.groupID ?? UUID(), origin: .liveSpeech)
        example.suggestedPersonID = allowedSuggestion(for: example, personID: suggestion)
        example.review = example.suggestedPersonID == nil ? .unassigned : .suggested
        return upsert([example])
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
                || examples.contains(where: { $0.meetingID == meeting.id && $0.isReviewed })
                || meeting.speakers.contains(where: { $0.voiceReviewOrigin != nil })
        else { return meeting }
        let evidence = examples.filter {
            $0.meetingID == meeting.id
                && ($0.review == .confirmed || $0.review == .rejected
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
                return range.audioFile == file && row.start >= range.start && row.end <= range.end
            }
            guard let first = relevant.first else { continue }
            let people = Set(relevant.map { $0.review == .confirmed ? $0.personID : nil })
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
