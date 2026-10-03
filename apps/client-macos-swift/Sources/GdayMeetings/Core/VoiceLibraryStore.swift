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
    private let write: (Data, URL) throws -> Void
    private var loadedData: Data?
    private var readable = true
    private var pendingDocument: VoiceLibraryDocument?
    private var pendingData: Data?
    private struct ProjectionCacheEntry {
        var input: Meeting
        var output: Meeting
        var evidenceIDs: Set<UUID>
    }
    private var projectionCache: [UUID: ProjectionCacheEntry] = [:]
    private var deletedPeople: [UUID] = []
    var didChange: ((Set<UUID>) -> Void)?

    init(
        directory: URL, legacyPeople: [Person] = [], canWrite: @escaping () -> Bool = { true },
        write: @escaping (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(
                ".voice-library-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard
                FileManager.default.createFile(
                    atPath: temporary.path, contents: data,
                    attributes: [.posixPermissions: 0o600])
            else {
                throw ServiceError("Couldn’t write the voice library.")
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly)
            }
            else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        }
    ) {
        url = directory.appendingPathComponent("voice-library.json")
        self.canWrite = canWrite
        self.write = write
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(VoiceLibraryDocument.self, from: data)
                guard decoded.version == 1 else {
                    throw ServiceError("This voice library needs a newer version of Gday Meetings.")
                }
                guard Set(decoded.examples.map(\.id)).count == decoded.examples.count else {
                    throw ServiceError("The voice library contains duplicate sample identifiers.")
                }
                document = decoded
                loadedData = data
            }
            else {
                // Old assignments do not establish that a person reviewed the
                // exact audio used for an embedding. Keep them as suggestions.
                for person in legacyPeople {
                    for sample in person.voiceSamples {
                        document.examples.append(
                            VoiceExample(
                                meetingID: sample.meetingID, speakerID: sample.speakerID, source: "unknown",
                                suggestedPersonID: person.id, review: .suggested,
                                embeddings: [sample.resolvedVoiceEmbedding]))
                    }
                }
            }
            publish()
        }
        catch {
            readable = false
            errorMessage = "Couldn’t open the voice library. \(error.localizedDescription)"
        }
    }

    private func publish() {
        if examples != document.examples || decisions != document.decisions
            || deletedPeople != document.deletedPersonIDs
        {
            projectionCache.removeAll()
        }
        deletedPeople = document.deletedPersonIDs
        examples = document.examples
        decisions = document.decisions
        canUndo = !document.undo.isEmpty
        if jobs != document.jobs { jobs = document.jobs }
    }

    private func commit(_ next: VoiceLibraryDocument, changed: Set<UUID> = []) -> Bool {
        guard readable, canWrite() else {
            errorMessage = "The voice library is read-only. Check the data folder before saving changes."
            return false
        }
        do {
            let disk = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard disk == loadedData else {
                throw ServiceError("The voice library changed on disk. Reopen the library before editing it.")
            }
            let data = try JSONEncoder().encode(next)
            try write(data, url)
            loadedData = data
            document = next
            errorMessage = nil
            publish()
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
        examples.filter { $0.personID == personID || $0.suggestedPersonID == personID }
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
        var next = document
        next.jobs = jobs
        return commit(next)
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

    /// Automatic matching uses only reviewed, playable evidence. Legacy vectors
    /// remain inspectable but cannot silently become enrollment data.
    func matchingPeople(from people: [Person]) -> [Person] {
        people.map { person in
            var value = person
            value.voiceSamples = examples.filter {
                $0.personID == person.id && $0.review == .confirmed && !$0.excluded && audioIsCurrent($0)
                    && !hasConflictingReview($0)
            }.flatMap { example in
                example.embeddings.filter(\.isValid).map {
                    PersonVoiceSample(meetingID: example.meetingID, speakerID: example.id, voiceEmbedding: $0)
                }
            }
            return value
        }
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

    func suggestReviewedPeople(from people: [Person]) {
        let profiles = matchingPeople(from: people)
        var next = document
        for index in next.examples.indices {
            let example = next.examples[index]
            guard !example.isReviewed, audioIsCurrent(example) else { continue }
            let matches = example.embeddings.compactMap { SpeakerRecognition.match(embedding: $0, people: profiles) }
            let candidates = Set(matches.map(\.personID))
            let person = allowedSuggestion(for: example, personID: candidates.count == 1 ? candidates.first : nil)
            next.examples[index].suggestedPersonID = person
            next.examples[index].review = person == nil ? .unassigned : .suggested
        }
        if next.examples != examples { _ = commit(next) }
    }

    /// Rejections are evidence, not global person bans. Exact reviewed audio is
    /// authoritative; novel voices remain suggestions until explicitly reviewed.
    func rejectedPeople(meetingID: UUID, speakerID: UUID) -> Set<UUID> {
        Set(examples.filter { $0.meetingID == meetingID && $0.speakerID == speakerID }.flatMap(\.rejectedPersonIDs))
    }

    @discardableResult
    func suggest(exampleID: UUID, personID: UUID?) -> Bool {
        guard let index = document.examples.firstIndex(where: { $0.id == exampleID }),
            !document.examples[index].isReviewed
        else { return true }
        var next = document
        let candidate = allowedSuggestion(for: next.examples[index], personID: personID)
        guard next.examples[index].suggestedPersonID != candidate else { return true }
        next.examples[index].suggestedPersonID = candidate
        next.examples[index].review = candidate == nil ? .unassigned : .suggested
        return commit(next)
    }

    private func allowedSuggestion(for example: VoiceExample, personID: UUID?) -> UUID? {
        if let personID {
            if document.deletedPersonIDs.contains(personID) || example.rejectedPersonIDs.contains(personID)
                || example.embeddings.contains(where: { embedding in
                    examples.contains { rejected in
                        rejected.rejectedPersonIDs.contains(personID)
                            && rejected.embeddings.contains {
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
                    if !finalizeLive { next.examples[index].embeddings = [] }
                }
                guard commit(next) else { return false }
                continue
            }
            var range = speaker.voiceSampleRange
            // A saved range does not prove that a saved vector describes the
            // file currently at that path. Reuse only its recorded revision.
            var embedding: TypedVoiceEmbedding?
            if let range, let revision = speaker.voiceSampleRevision,
                Self.revision(url: directory.appendingPathComponent(range.audioFile)) == revision
            {
                embedding = speaker.voiceEmbedding
            }
            if range == nil {
                // A legacy centroid has no recoverable excerpt boundary. A new
                // excerpt must receive its own embedding before it can train.
                embedding = nil
                let file: String?
                if speaker.track.hasPrefix("track"), let index = Int(speaker.track.dropFirst(5)),
                    meeting.audioFiles.indices.contains(index)
                {
                    file = meeting.audioFiles[index]
                }
                else {
                    let candidates = meeting.audioFiles.filter {
                        let source = LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0))
                        return source == speaker.track || (source == "microphone" && speaker.track == "mic")
                            || (source == "system" && speaker.track == "system_mix")
                    }
                    file =
                        candidates.count == 1
                        ? candidates[0] : (meeting.audioFiles.count == 1 ? meeting.audioFiles[0] : nil)
                }
                if let file,
                    let segment = meeting.transcript.filter({ row in
                        row.speakerID == speaker.id && row.start.isFinite && row.end.isFinite
                            && row.start >= 0 && row.end - row.start >= 2
                    }).sorted(by: { $0.end - $0.start > $1.end - $1.start }).first(where: { row in
                        !meeting.transcript.contains(where: { other in
                            guard other.speakerID != speaker.id, other.start < row.end, other.end > row.start else {
                                return false
                            }
                            guard let competitor = meeting.speakers.first(where: { $0.id == other.speakerID }) else {
                                return true
                            }
                            return competitor.track == speaker.track || competitor.track.isEmpty
                                || speaker.track.isEmpty
                        })
                    })
                {
                    range = .init(
                        audioFile: file, source: speaker.track, start: segment.start,
                        end: min(segment.end, segment.start + 10))
                }
            }
            guard let range, range.isValid else { continue }
            let prior = examples.first { $0.meetingID == meeting.id && $0.speakerID == speaker.id }
            additions.append(
                VoiceExample(
                    meetingID: meeting.id, speakerID: speaker.id, source: range.source,
                    audioFile: range.audioFile,
                    audioRevision: Self.revision(url: directory.appendingPathComponent(range.audioFile)),
                    start: range.start, end: range.end,
                    suggestedPersonID: speaker.personID ?? prior?.suggestedPersonID,
                    review: (speaker.personID ?? prior?.suggestedPersonID) == nil ? .unassigned : .suggested,
                    embeddings: embedding.map { [$0] } ?? [], groupID: prior?.groupID ?? UUID()))
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
            embeddings: [embedding], groupID: existing.first?.groupID ?? UUID())
        example.suggestedPersonID = allowedSuggestion(for: example, personID: suggestion)
        example.review = example.suggestedPersonID == nil ? .unassigned : .suggested
        return upsert([example])
    }

    @discardableResult
    func assign(
        meetingID: UUID, speakerID: UUID, personID: UUID?, staged: Bool = false,
        previousPersonID: UUID? = nil, exampleID: UUID? = nil
    ) -> Bool {
        guard readable, canWrite() else { return false }
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
        let disk = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard disk == loadedData else {
            throw ServiceError("The voice library changed on disk. Reopen it before editing.")
        }
        try transaction.remember(url)
        let data = try JSONEncoder().encode(pendingDocument)
        try write(data, url)
        pendingData = data
    }

    func completePending(committed: Bool) {
        if committed, let pendingDocument {
            document = pendingDocument
            loadedData = pendingData
            publish()
        }
        pendingDocument = nil
        pendingData = nil
    }

    func applyingDecisions(to meeting: Meeting) -> Meeting {
        var updated = meeting
        guard
            decisions.contains(where: { $0.meetingID == meeting.id })
                || examples.contains(where: { $0.meetingID == meeting.id && $0.isReviewed })
                || meeting.speakers.contains(where: { $0.voiceReviewOrigin != nil })
        else { return meeting }
        let evidence = examples.filter {
            $0.meetingID == meeting.id && ($0.review == .confirmed || $0.review == .rejected || $0.manuallyCleared)
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
        if projectionCache.count >= 16 { projectionCache.removeAll() }
        projectionCache[meeting.id] = .init(input: meeting, output: updated, evidenceIDs: evidenceIDs)
        return updated
    }

    @discardableResult
    func removePerson(id: UUID, staged: Bool = false) -> Bool {
        guard readable, canWrite() else { return false }
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
