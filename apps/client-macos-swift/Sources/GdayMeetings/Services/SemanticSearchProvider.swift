import Foundation

struct SemanticSearchProvider: SearchIndexProvider {
    let id: UUID
    let configuration: LocalSearchConfiguration
    let directory: URL
    let index: SemanticSearchIndex
    let encoder: any SemanticEmbedding
    var logsSearch = true
    var searchLog: SearchLog? { logsSearch ? .init(directory: directory, providerID: id) : nil }
    var descriptor: SearchProviderDescriptor { .init(id: id, name: "Local Search", modes: [.semantic]) }
    func prepare() async throws {
        try await index.prepare(model: configuration.selectedModel)
        try await encoder.prepare()
    }
    func unload() async {
        await encoder.unload()
        await index.unload()
    }
    func resetIndex() async throws { try await index.reset(space: configuration.selectedModel.space) }
    func removeIndex(meetingID: UUID) async throws { try await index.remove(meetingID) }

    func updateIndex(
        meetingID: UUID, rebuild: Bool = false, progress: @escaping @Sendable (SearchIndexProgress) -> Void
    ) async throws {
        _ = try await updateIndex(meetingID: meetingID, rebuild: rebuild, refresh: false, progress: progress)
    }

    /// Rebuild stored index rows while retaining vectors for unchanged passages.
    func refreshIndex(meetingID: UUID, progress: @escaping @Sendable (SearchIndexProgress) -> Void) async throws {
        _ = try await updateIndex(meetingID: meetingID, rebuild: false, refresh: true, progress: progress)
    }

    func indexWithMeasurement(
        meetingID: UUID, refresh: Bool, progress: @escaping @Sendable (SearchIndexProgress) -> Void
    ) async throws -> SearchIndexProgress? {
        try await updateIndex(meetingID: meetingID, rebuild: false, refresh: refresh, progress: progress)
    }

    private func updateIndex(
        meetingID: UUID, rebuild: Bool, refresh: Bool,
        progress: @escaping @Sendable (SearchIndexProgress) -> Void
    ) async throws -> SearchIndexProgress? {
        let directory = directory
        let model = configuration.selectedModel
        let (folder, fingerprint, meeting) = try await Task.detached(priority: .utility) {
            let folder = try MeetingFolderLocation.resolve(id: meetingID, directory: directory)
            let meeting = try SemanticSource.read(folder: folder)
            return (folder, try SemanticSource.fingerprint(meeting), meeting)
        }.value
        try Task.checkCancellation()
        if !rebuild, !refresh, try await index.isCurrent(meetingID, space: model.space, fingerprint: fingerprint) {
            return nil
        }
        var windows: [SemanticWindow] = []
        for window in SemanticSource.windows(meeting) {
            for (part, text) in (try await encoder.passageParts(window.text)).enumerated() {
                var divided = window
                divided.id += ":\(part)"
                divided.text = text
                windows.append(divided)
            }
        }
        let revision = SemanticSource.hash(
            Data(
                windows.map {
                    "\($0.id):\($0.start ?? -1):\($0.end ?? -1):\($0.track ?? ""):\($0.people.map(\.uuidString).sorted().joined(separator: ",")):\($0.text)"
                }.joined(separator: "\n").utf8))
        let reusable: [String: SemanticWindow] = await Task.detached(priority: .utility) {
            guard !rebuild,
                let old = try? PackedSemanticArtifact.read(folder: folder, space: model.space, meetingID: meetingID)
            else { return [:] }
            return Dictionary(old.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }.value
        let reused = windows.map { window in
            guard let old = reusable[window.id], old.text == window.text,
                old.vector.count == model.dimensions, old.vector.allSatisfy(\.isFinite),
                abs(old.vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.0001
            else { return false }
            return true
        }
        var remainingCharacters = windows.indices.filter { !reused[$0] }.reduce(0) { $0 + windows[$1].text.count }
        var embeddedCharacters = 0
        var embeddingSeconds = 0.0
        func report(_ completed: Int, persisted: Bool = false) {
            progress(
                .init(
                    meetingID: meetingID, completed: completed, total: windows.count,
                    remainingCharacters: remainingCharacters, embeddedCharacters: embeddedCharacters,
                    embeddingSeconds: embeddingSeconds, persisted: persisted))
        }
        report(0)
        var lastProgress = ContinuousClock.now
        for position in windows.indices {
            try Task.checkCancellation()
            if reused[position], let old = reusable[windows[position].id] {
                windows[position].vector = old.vector
            }
            else {
                let measurement = try await encoder.embedMeasured(windows[position].text, isQuery: false)
                windows[position].vector = measurement.vector
                let characters = windows[position].text.count
                if let seconds = measurement.processingSeconds, seconds.isFinite, seconds > 0 {
                    embeddingSeconds += seconds
                    embeddedCharacters += characters
                }
                remainingCharacters -= characters
            }
            if position + 1 == windows.count || lastProgress.duration(to: .now) >= .milliseconds(250) {
                report(position + 1)
                lastProgress = .now
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        try await index.persist(
            .init(space: model.space, meetingID: meetingID, revision: revision, windows: windows),
            fingerprint: fingerprint)
        return .init(
            meetingID: meetingID, completed: windows.count, total: windows.count,
            remainingCharacters: 0, embeddedCharacters: embeddedCharacters,
            embeddingSeconds: embeddingSeconds, persisted: true)
    }

    func search(_ request: ProviderSearchRequest) -> AsyncThrowingStream<ProviderResult<ProviderSearchSnapshot>, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock.now
                let model = configuration.selectedModel
                let manifest = LocalModelRegistry.descriptor(model.localID)
                let settings = [
                    "embeddingModel": model.rawValue, "embeddingSpace": model.space,
                    "modelRepository": manifest.repository, "modelRevision": manifest.revision,
                    "modelAssetsDigest": SemanticSource.hash(
                        Data(manifest.assets.map { $0.path + ":" + $0.digest }.joined(separator: "\n").utf8)),
                    "dimensions": String(model.dimensions), "reranker": "fp32-cosine-speaker-boost-v1",
                    "speakerMatchBoost": String(configuration.boost), "retriever": "usearch-2.26.4-int8-hnsw",
                    "candidateLimit": "1000", "connectivity": "32", "expansionSearch": "2000",
                    "peopleResolver": "PeopleNameIndex-v1",
                ]
                searchLog?.record(
                    .init(
                        kind: "search_started", requestID: request.id, submissionID: request.submissionID,
                        request: request, configuration: settings))
                do {
                    guard request.mode == .semantic else { throw SearchProviderError.unsupportedMode }
                    let started = Date()
                    let query = try await encoder.embed(request.query, isQuery: true)
                    let embeddingMS = SearchLog.milliseconds(since: clock)
                    let outcome = try await index.searchWithTrace(
                        vector: query, model: configuration.selectedModel, request: request, boost: configuration.boost)
                    let results = outcome.results
                    let snapshot = ProviderSearchSnapshot(
                        requestID: request.id, providerID: id, sequence: 0,
                        results: results, total: results.count, nextCursor: nil, isFinal: true)
                    try Task.checkCancellation()
                    searchLog?.record(
                        .init(
                            kind: "search_completed", requestID: request.id, submissionID: request.submissionID,
                            timingsMS: ["embedding": embeddingMS, "total": SearchLog.milliseconds(since: clock)],
                            snapshot: snapshot, retrieval: outcome.trace))
                    continuation.yield(
                        .init(
                            value: snapshot,
                            dataFlow: .init(
                                location: .local, targetID: id, targetName: "Local Search", startedAt: started,
                                endedAt: Date(), bodies: ["Search query"], purpose: "Search meeting content by meaning")
                        ))
                    continuation.finish()
                }
                catch {
                    searchLog?.record(
                        .init(
                            kind: Task.isCancelled || error is CancellationError ? "search_cancelled" : "search_failed",
                            requestID: request.id, submissionID: request.submissionID,
                            timingsMS: ["total": SearchLog.milliseconds(since: clock)],
                            error: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
