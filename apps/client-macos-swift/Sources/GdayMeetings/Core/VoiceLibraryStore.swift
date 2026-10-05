import Combine
import Foundation

@MainActor
final class VoiceLibraryStore: ObservableObject {
    @Published private(set) var examples: [VoiceExample] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var jobs: [VoicePreparationJob] = []
    private(set) var decisions: [VoiceSpeakerDecision] = []
    private var document = VoiceLibraryDocument()
    private let url: URL
    private let canWrite: () -> Bool
    private var persistence: VoiceLibraryPersistence?
    private var hydratedIDs: Set<UUID> = []
    private var exampleIndices: [UUID: Int] = [:]
    private var personExampleIDs: [UUID: Set<UUID>] = [:]
    @Published private(set) var representationsRevision = 0
    private var readable = true
    private var pendingDocument: VoiceLibraryDocument?
    private struct ProjectionCacheEntry {
        var input: Meeting
        var output: Meeting
        var evidenceIDs: Set<UUID>
    }
    private var projectionCache: [UUID: ProjectionCacheEntry] = [:]
    private var deletedPeople: [UUID] = []
    var didChange: ((Set<UUID>) -> Void)?

    init(
        directory: URL, canWrite: @escaping () -> Bool = { true },
        write: ((Data, URL) throws -> Void)? = nil
    ) {
        url = directory.appendingPathComponent("voice-library")
        self.canWrite = canWrite
        do {
            let persistence = try VoiceLibraryPersistence(directory: directory, writable: canWrite(), write: write)
            self.persistence = persistence
            document = try persistence.load() ?? VoiceLibraryDocument()
            publish()
        }
        catch {
            readable = false
            errorMessage = "Couldn’t open the voice library. \(error.localizedDescription)"
        }
    }

    /// Metadata is available immediately. Representations are read only when a
    /// selected example or an explicit association operation needs them.
    func hydratedExample(id: UUID) -> VoiceExample? {
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
        guard readable, canWrite(), let persistence else {
            errorMessage = "The voice library is read-only. Check the data folder before saving changes."
            return false
        }
        do {
            try persistence.commit(previous: document, next: next)
            let changedRepresentations = next.examples.contains { value in
                guard let index = exampleIndices[value.id] else {
                    return !value.embeddings.isEmpty
                }
                return document.examples[index].embeddings != value.embeddings
            }
            document = next
            if changedRepresentations { representationsRevision += 1 }
            errorMessage = persistence.maintenanceWarning
            publish()
            hydratedIDs.formUnion(
                document.examples.filter { !$0.embeddings.isEmpty }.map(\.id))
            releaseRepresentations()
            if !changed.isEmpty { didChange?(changed) }
            return true
        }
        catch {
            errorMessage = "Couldn’t save the voice library. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func upsert(_ incoming: [VoiceExample]) -> Bool {
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
        guard jobs != document.jobs else { return true }
        guard readable, canWrite(), let persistence else {
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
    func matchingPeople(from people: [Person]) -> [Person] {
        defer { releaseRepresentations() }
        return people.map { person in
            var value = person
            value.voiceSamples = examples.filter {
                $0.personID == person.id && $0.review == .confirmed && !$0.excluded
                    && !hasConflictingReview($0)
            }.flatMap { example in
                (hydratedExample(id: example.id)?.voiceEmbeddings ?? []).filter(\.isValid).map {
                    PersonVoiceSample(meetingID: example.meetingID, speakerID: example.id, voiceEmbedding: $0)
                }
            }
            return value
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

    func suggestReviewedPeople(from people: [Person]) {
        defer { releaseRepresentations() }
        let profiles = matchingPeople(from: people)
        let candidates = examples.filter { !$0.isReviewed || !$0.rejectedPersonIDs.isEmpty }
        for example in candidates { guard hydratedExample(id: example.id) != nil else { return } }
        var next = document
        for index in next.examples.indices {
            let example = next.examples[index]
            guard !example.isReviewed else { continue }
            let matches = example.voiceEmbeddings.compactMap {
                SpeakerRecognition.match(embedding: $0, people: profiles)
            }
            let candidates = Set(matches.map(\.personID))
            let person = allowedSuggestion(for: example, personID: candidates.count == 1 ? candidates.first : nil)
            next.examples[index].suggestedPersonID = person
            next.examples[index].review = person == nil ? .unassigned : .suggested
        }
        if next.examples != document.examples { _ = commit(next) }
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
        guard readable, canWrite(), persistence != nil else { return false }
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

    func writePending(transaction: inout LibraryFileTransaction) throws {
        guard let pendingDocument else { return }
        guard let persistence else { throw ServiceError("The voice library is unavailable.") }
        try persistence.commit(previous: document, next: pendingDocument, transaction: &transaction)
    }

    func completePending(committed: Bool) {
        guard let pendingDocument else { return }
        if committed {
            document = pendingDocument
            publish()
        }
        do { try persistence?.reloadRevision(committed: committed) }
        catch {
            readable = false
            errorMessage = "Couldn’t refresh the voice library. \(error.localizedDescription)"
        }
        self.pendingDocument = nil
    }

    func applyingDecisions(to meeting: Meeting) -> Meeting {
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
            if speaker.track.hasPrefix("track"), let track = Int(speaker.track.dropFirst(5)),
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
                manuallyAssigned: speaker.manuallyAssigned, confidence: speaker.confidence)
            assigned.voiceReviewExampleID = first.id
            assigned.personID = people.count == 1 ? people.first! : nil
            assigned.manuallyAssigned = true
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
        guard !ids.isEmpty, !ids.contains(targetID), readable, canWrite(), persistence != nil,
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
        guard readable, canWrite(), persistence != nil else { return false }
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
