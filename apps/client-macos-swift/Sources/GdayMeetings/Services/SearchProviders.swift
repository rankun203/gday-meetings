import Foundation

/// Text and voice are retrieval channels; fusion combines their independently ranked outputs.
enum SearchMode: String, Codable, CaseIterable, Sendable { case text, voice, fusion }

struct SearchProviderDescriptor: Sendable {
    let id: UUID
    let name: String
    let modes: Set<SearchMode>
}

struct ProviderSearchRequest: Sendable {
    var id = UUID()
    var query: String
    var mode: SearchMode = .text
    var limit = 50
    var after: Int64 = 0
    var excludingTagIDs: Set<UUID> = []
    /// Ranked pages use an offset cursor; legacy passage-order pages use a passage ID.
    var ranked = false
}

struct ProviderSearchAudioRange: Equatable, Codable, Sendable {
    let filename: String
    let start: Double
    let duration: Double
}

struct ProviderSearchResult: Identifiable, Equatable, Sendable {
    /// Stable within the provider and source revision, independent of streaming event order.
    let id: String
    let meetingID: UUID
    let title: String
    let excerpt: String
    let sourceRevision: String?
    let passage: LibrarySearchResult?
    var audio: ProviderSearchAudioRange? = nil
    var createdAt: Date? = nil
}

struct ProviderSearchSnapshot: Sendable {
    let requestID: UUID
    let providerID: UUID
    let sequence: Int
    let results: [ProviderSearchResult]
    let total: Int?
    let nextCursor: Int64?
    /// Completion applies to this requested page, not to the library's index coverage.
    let isFinal: Bool
}

protocol SearchProvider: Sendable {
    var descriptor: SearchProviderDescriptor { get }
    func search(_ request: ProviderSearchRequest) -> AsyncThrowingStream<ProviderResult<ProviderSearchSnapshot>, Error>
}

protocol SearchIndexProvider: SearchProvider {
    func index(_ document: ProviderSearchDocument) async throws -> ProviderResult<Void>
    func remove(meetingID: String) async throws -> ProviderResult<Void>
}

enum SearchProviderError: Error, LocalizedError {
    case unsupportedMode, incompleteResponse, invalidResponse
    var errorDescription: String? {
        switch self {
        case .unsupportedMode: "This search provider doesn’t support the selected search mode."
        case .incompleteResponse: "The search provider stopped before returning a complete result."
        case .invalidResponse: "The search provider returned an invalid result."
        }
    }
}

/// Built-in lexical retrieval uses the same asynchronous capability boundary as other providers.
struct LocalTextSearchProvider: SearchProvider {
    static let id = UUID(uuidString: "838E72BD-5E66-4A76-956B-A90A979DEAB2")!
    let index: LibraryIndex
    var descriptor: SearchProviderDescriptor {
        .init(id: Self.id, name: "Library Text Search", modes: [.text])
    }

    func search(_ request: ProviderSearchRequest) -> AsyncThrowingStream<ProviderResult<ProviderSearchSnapshot>, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    guard request.mode == .text else { throw SearchProviderError.unsupportedMode }
                    try Task.checkCancellation()
                    let started = Date()
                    let limit = max(1, min(request.limit, 100))
                    let page = try index.searchPage(
                        query: request.query, after: request.after, limit: limit,
                        excludingTagIDs: request.excludingTagIDs, ranked: request.ranked)
                    try Task.checkCancellation()
                    let results = page.results.map { passage in
                        ProviderSearchResult(
                            id: String(passage.id), meetingID: passage.meetingID, title: passage.title,
                            excerpt: passage.excerpt, sourceRevision: nil, passage: passage)
                    }
                    continuation.yield(
                        .init(
                            value: .init(
                                requestID: request.id, providerID: Self.id, sequence: 0, results: results,
                                total: page.total,
                                nextCursor: results.count == limit
                                    ? (request.ranked ? request.after + Int64(results.count) : page.results.last?.id)
                                    : nil,
                                isFinal: true),
                            dataFlow: .init(
                                location: .local, targetID: Self.id, targetName: descriptor.name,
                                startedAt: started, endedAt: Date(), bodies: ["Search query"],
                                purpose: "Search the local library index")))
                    continuation.finish()
                }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func page(query: String, after: Int64, excludingTagIDs: Set<UUID>) async throws -> LibrarySearchPage {
        let request = ProviderSearchRequest(query: query, after: after, excludingTagIDs: excludingTagIDs)
        for try await event in search(request) {
            try Task.checkCancellation()
            guard event.value.requestID == request.id, event.value.providerID == Self.id else {
                throw SearchProviderError.invalidResponse
            }
            if event.value.isFinal {
                return .init(results: event.value.results.compactMap(\.passage), total: event.value.total ?? 0)
            }
        }
        throw SearchProviderError.incompleteResponse
    }
}

struct FusedSearchResult: Identifiable, Sendable {
    var id: UUID { meetingID }
    let meetingID: UUID
    let score: Double
    let evidence: [ProviderSearchResult]
}

/// Replace each provider's snapshot so repeated streaming events cannot multiply its vote.
struct ReciprocalRankFusion: Sendable {
    private(set) var snapshots: [UUID: ProviderSearchSnapshot] = [:]
    let requestID: UUID
    private let weights: [UUID: Double]
    private let rankConstant: Double

    init(requestID: UUID, weights: [UUID: Double], rankConstant: Double = 60) {
        self.requestID = requestID
        self.weights = weights.filter { $0.value.isFinite && $0.value > 0 }
        self.rankConstant = rankConstant.isFinite && rankConstant >= 0 ? rankConstant : 60
    }

    @discardableResult mutating func accept(_ snapshot: ProviderSearchSnapshot) -> Bool {
        guard snapshot.requestID == requestID, snapshot.sequence >= 0, weights[snapshot.providerID] != nil else {
            return false
        }
        if let previous = snapshots[snapshot.providerID] {
            guard !previous.isFinal, snapshot.sequence > previous.sequence else { return false }
        }
        snapshots[snapshot.providerID] = snapshot
        return true
    }

    var isComplete: Bool {
        !weights.isEmpty && weights.keys.allSatisfy { snapshots[$0]?.isFinal == true }
    }

    func results(limit: Int) -> [FusedSearchResult] {
        var scores: [UUID: Double] = [:]
        var evidence: [UUID: [ProviderSearchResult]] = [:]
        // Stable iteration also makes floating-point sums and evidence order deterministic.
        for providerID in weights.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let snapshot = snapshots[providerID], let weight = weights[providerID] else { continue }
            var seen: Set<UUID> = []
            var rank = 0
            for result in snapshot.results where seen.insert(result.meetingID).inserted {
                rank += 1
                scores[result.meetingID, default: 0] += weight / (rankConstant + Double(rank))
                evidence[result.meetingID, default: []].append(result)
            }
        }
        var ranked: [FusedSearchResult] = scores.map { meetingID, score in
            FusedSearchResult(meetingID: meetingID, score: score, evidence: evidence[meetingID] ?? [])
        }
        ranked.sort { left, right in
            if left.score == right.score { return left.id.uuidString < right.id.uuidString }
            return left.score > right.score
        }
        return Array(ranked.prefix(max(0, limit)))
    }
}
