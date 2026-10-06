import Foundation

struct SemanticSearchProvider: SearchIndexProvider {
    let id: UUID
    let configuration: LocalSearchConfiguration
    let directory: URL
    let index: SemanticSearchIndex
    let encoder: any SemanticEmbedding
    var descriptor: SearchProviderDescriptor { .init(id: id, name: "Local Search", modes: [.semantic]) }
    func prepare() async throws { try await encoder.prepare() }
    func unload() async { await encoder.unload() }
    func resetIndex() async throws { try await index.reset(space: configuration.selectedModel.space) }
    func removeIndex(meetingID: UUID) async throws { try await index.remove(meetingID) }

    func updateIndex(
        meetingID: UUID, rebuild: Bool = false, progress: @escaping @Sendable (SearchIndexProgress) -> Void
    ) async throws {
        let directory = directory
        let model = configuration.selectedModel
        let (folder, fingerprint, meeting) = try await Task.detached(priority: .utility) {
            let folder = try MeetingFolderLocation.resolve(id: meetingID, directory: directory)
            let fingerprint = try SemanticSource.fingerprint(folder: folder)
            return (folder, fingerprint, try MeetingFolderStorage.read(id: meetingID, directory: directory))
        }.value
        try Task.checkCancellation()
        if !rebuild, try await index.isCurrent(meetingID, space: model.space, fingerprint: fingerprint) { return }
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
        let saved = folder.appendingPathComponent(
            "providers/local-search/" + SemanticSource.hash(Data(model.space.utf8)) + "/embeddings.json")
        let reusable: [String: SemanticWindow] = await Task.detached(priority: .utility) {
            guard !rebuild,
                saved.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/providers/"),
                let data = try? Data(contentsOf: saved),
                let old = try? JSONDecoder().decode(SemanticMeetingArtifact.self, from: data),
                old.space == model.space, old.meetingID == meetingID
            else { return [:] }
            return Dictionary(old.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }.value
        progress(.init(meetingID: meetingID, completed: 0, total: windows.count))
        for position in windows.indices {
            try Task.checkCancellation()
            if let old = reusable[windows[position].id], old.text == windows[position].text,
                old.vector.count == model.dimensions, old.vector.allSatisfy(\.isFinite),
                abs(old.vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.0001
            {
                windows[position].vector = old.vector
            }
            else {
                windows[position].vector = try await encoder.embed(windows[position].text, isQuery: false)
            }
            progress(.init(meetingID: meetingID, completed: position + 1, total: windows.count))
            await Task.yield()
        }
        try Task.checkCancellation()
        try await index.persist(
            .init(space: model.space, meetingID: meetingID, revision: revision, windows: windows),
            fingerprint: fingerprint)
    }

    func search(_ request: ProviderSearchRequest) -> AsyncThrowingStream<ProviderResult<ProviderSearchSnapshot>, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard request.mode == .semantic else { throw SearchProviderError.unsupportedMode }
                    let started = Date()
                    let query = try await encoder.embed(request.query, isQuery: true)
                    let results = try await index.search(
                        vector: query, model: configuration.selectedModel, request: request, boost: configuration.boost)
                    try Task.checkCancellation()
                    continuation.yield(
                        .init(
                            value: .init(
                                requestID: request.id, providerID: id, sequence: 0,
                                results: results, total: results.count, nextCursor: nil, isFinal: true),
                            dataFlow: .init(
                                location: .local, targetID: id, targetName: "Local Search", startedAt: started,
                                endedAt: Date(), bodies: ["Search query"], purpose: "Search meeting content by meaning")
                        ))
                    continuation.finish()
                }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
