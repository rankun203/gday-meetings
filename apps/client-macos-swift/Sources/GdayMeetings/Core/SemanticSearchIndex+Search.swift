import Accelerate
import CSQLite
import Foundation

extension SemanticSearchIndex {
    struct RankedWindow {
        let key: Int64
        let id: String
        let score: SpeakerMatchScore
    }
    func search(vector: [Double], model: SemanticModelID, request: ProviderSearchRequest, boost: Double) throws
        -> [ProviderSearchResult]
    {
        try searchWithTrace(vector: vector, model: model, request: request, boost: boost).results
    }
    func searchWithTrace(vector: [Double], model: SemanticModelID, request: ProviderSearchRequest, boost: Double) throws
        -> (results: [ProviderSearchResult], trace: SearchRetrievalTrace)
    {
        try autoreleasepool { try searchWindows(vector: vector, model: model, request: request, boost: boost) }
    }
    private func searchWindows(vector: [Double], model: SemanticModelID, request: ProviderSearchRequest, boost: Double)
        throws
        -> (results: [ProviderSearchResult], trace: SearchRetrievalTrace)
    {
        var trace = SearchRetrievalTrace()
        let started = ContinuousClock.now
        guard vector.count == model.dimensions, vector.allSatisfy(\.isFinite) else {
            throw SearchProviderError.invalidResponse
        }
        let limit = max(0, min(request.limit, 100))
        guard limit > 0 else { return ([], trace) }
        try Task.checkCancellation()
        try connection.execute("BEGIN")
        do {
            let graph = try ensureGraph(space: model.space, dimensions: model.dimensions)
            trace.indexEpoch = graphEpoch
            trace.indexSequence = graphSequence
            trace.timingsMS["indexPreparation"] = SearchLog.milliseconds(since: started)
            let filteringStarted = ContinuousClock.now
            let query = vector.map(Float.init)
            var excluded = Set<Int64>()
            for tag in request.excludingTagIDs {
                excluded.formUnion(
                    try keys(
                        "SELECT w.key FROM provider_semantic_windows w JOIN provider_semantic_tags t ON w.space=t.space AND w.meeting=t.meeting WHERE t.space=? AND t.tag=?",
                        strings: [model.space, tag.uuidString]))
            }
            var speakers: [Int64: Set<UUID>] = [:]
            if !request.identifiedPeople.isEmpty {
                for person in request.identifiedPeople {
                    for key in try keys(
                        "SELECT key FROM provider_semantic_people WHERE space=? AND person=?",
                        strings: [model.space, person.uuidString])
                    {
                        speakers[key, default: []].insert(person)
                    }
                }
            }
            trace.timingsMS["filters"] = SearchLog.milliseconds(since: filteringStarted)
            var freshness: [String: Bool] = [:]
            var ranked: [RankedWindow] = []
            // Reject stale meetings and refill the ANN budget. The loop excludes at least
            // one whole meeting each time, so stale rows cannot starve current results.
            while true {
                try Task.checkCancellation()
                let annStarted = ContinuousClock.now
                let ann = try graph.searchMatches(query, count: 1000, excluding: excluded)
                trace.timingsMS["ann", default: 0] += SearchLog.milliseconds(since: annStarted)
                let annPositions = Dictionary(
                    uniqueKeysWithValues: ann.enumerated().map { ($0.element.key, $0.offset) })
                var candidates = Set(ann.map(\.key))
                var loggedCandidates: [SearchRetrievalTrace.Candidate] = []
                let scoringStarted = ContinuousClock.now
                if !boost.isFinite || boost > 0 { candidates.formUnion(speakers.keys) }
                candidates.subtract(excluded)
                ranked = []
                var stale = Set<String>()
                for key in candidates.sorted() {
                    try Task.checkCancellation()
                    let statement = try connection.prepare(
                        "SELECT w.meeting,w.identity,w.fp32,m.fingerprint,m.revision FROM provider_semantic_windows w JOIN provider_semantic_meetings m ON w.space=m.space AND w.meeting=m.meeting WHERE w.key=? AND w.space=?"
                    )
                    defer { connection.release(statement) }
                    sqlite3_bind_int64(statement, 1, key)
                    bind(model.space, 2, statement)
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { continue }
                    guard step == SQLITE_ROW else { throw connection.failure() }
                    let meeting = text(statement, 0)
                    if freshness[meeting] == nil {
                        if let id = UUID(uuidString: meeting),
                            let folder = try? MeetingFolderLocation.resolve(id: id, directory: directory)
                        {
                            freshness[meeting] = (try? SemanticSource.fingerprint(folder: folder)) == text(statement, 3)
                        }
                        else {
                            freshness[meeting] = false
                        }
                    }
                    let position = annPositions[key]
                    let identity = meeting + ":" + text(statement, 1)
                    func candidate(_ score: SpeakerMatchScore?) -> SearchRetrievalTrace.Candidate {
                        .init(
                            key: key, resultID: identity, sourceRevision: text(statement, 4),
                            sourceFingerprint: text(statement, 3), annRank: position.map { $0 + 1 },
                            annDistance: position.map { ann[$0].distance },
                            speakerUnion: speakers[key] != nil && (!boost.isFinite || boost > 0),
                            accepted: score != nil, score: score)
                    }
                    guard freshness[meeting] == true else {
                        loggedCandidates.append(candidate(nil))
                        stale.insert(meeting)
                        continue
                    }
                    let values = try PackedSemanticArtifact.vector(blob(statement, 2), dimensions: model.dimensions)
                    var similarity: Float = 0
                    vDSP_dotpr(query, 1, values, 1, &similarity, vDSP_Length(model.dimensions))
                    guard similarity.isFinite else { throw SearchProviderError.invalidResponse }
                    let score = SpeakerMatchScore(
                        similarity: Double(similarity), identified: request.identifiedPeople,
                        speakers: speakers[key] ?? [], boost: boost)
                    loggedCandidates.append(candidate(score))
                    ranked.append(.init(key: key, id: identity, score: score))
                }
                trace.rounds.append(
                    .init(
                        candidates: loggedCandidates.sorted {
                            let left = $0.annRank ?? Int.max
                            let right = $1.annRank ?? Int.max
                            return left == right ? $0.resultID < $1.resultID : left < right
                        }))
                trace.timingsMS["candidateScoringAndFreshness", default: 0] += SearchLog.milliseconds(
                    since: scoringStarted)
                if stale.isEmpty { break }
                for meeting in stale {
                    excluded.formUnion(
                        try keys(
                            "SELECT key FROM provider_semantic_windows WHERE space=? AND meeting=?",
                            strings: [model.space, meeting]))
                }
            }
            let sortingStarted = ContinuousClock.now
            ranked.sort { $0.score.total == $1.score.total ? $0.id < $1.id : $0.score.total > $1.score.total }
            trace.reranked = ranked.map(\.id)
            trace.timingsMS["ranking"] = SearchLog.milliseconds(since: sortingStarted)
            let hydrationStarted = ContinuousClock.now
            var results: [ProviderSearchResult] = []
            // Only final rows decode display metadata; candidate ranking reads packed vectors.
            for match in ranked.prefix(limit) {
                let statement = try connection.prepare(
                    "SELECT w.metadata,m.entry,m.revision FROM provider_semantic_windows w JOIN provider_semantic_meetings m ON w.space=m.space AND w.meeting=m.meeting WHERE w.key=?"
                )
                defer { connection.release(statement) }
                sqlite3_bind_int64(statement, 1, match.key)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.failure() }
                let window = try JSONDecoder().decode(SemanticWindow.self, from: blob(statement, 0))
                let entry = try JSONDecoder().decode(MeetingListEntry.self, from: blob(statement, 1))
                let passage = LibrarySearchResult(
                    id: 0, meetingID: entry.id, title: entry.title, createdAt: entry.createdAt,
                    kind: LibrarySearchKind(rawValue: window.kind) ?? .transcript, segmentID: window.segmentID,
                    start: window.start, excerpt: window.text, end: window.end)
                let audio: ProviderSearchAudioRange? = window.track.flatMap { track in
                    guard let start = window.start, let end = window.end, end > start else { return nil }
                    return .init(filename: track, start: start, duration: end - start)
                }
                results.append(
                    .init(
                        id: match.id, meetingID: entry.id, title: entry.title, excerpt: window.text,
                        sourceRevision: text(statement, 2), passage: passage, audio: audio, createdAt: entry.createdAt,
                        scoreBreakdown: match.score))
            }
            try Task.checkCancellation()
            try connection.execute("COMMIT")
            try saveGraph()
            trace.timingsMS["hydrationAndCheckpoint"] = SearchLog.milliseconds(since: hydrationStarted)
            trace.timingsMS["indexTotal"] = SearchLog.milliseconds(since: started)
            return (results, trace)
        }
        catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }
}
