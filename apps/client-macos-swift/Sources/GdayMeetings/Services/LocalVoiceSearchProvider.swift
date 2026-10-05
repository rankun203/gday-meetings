import Foundation

protocol VoiceEmbeddingWorker: Sendable {
    func embed(texts: [String]) async throws -> LocalSearchEmbeddingResponse
    func embed(audio: URL, start: Double, duration: Double) async throws -> LocalSearchEmbeddingResponse
    func shutdown() async
}
extension LocalSearchWorkerClient: VoiceEmbeddingWorker {}

struct VoiceSearchBuildProgress: Sendable {
    let meetingID: UUID
    let audioFilename: String
    let completedClips: Int
    let totalClips: Int
}

/// The worker remains stopped until an explicit audio build or voice query.
/// Audio embeddings are committed as source artifacts before their disposable rows.
final class LocalVoiceSearchProvider: SearchProvider, @unchecked Sendable {
    static let id = VoiceSearchArtifacts.providerID
    let index: LocalVoiceSearchIndex
    private let worker: any VoiceEmbeddingWorker
    private let audioDuration: @Sendable (URL) async throws -> Double

    var descriptor: SearchProviderDescriptor {
        .init(id: Self.id, name: "Local Voice Search", modes: [.voice])
    }
    init(
        directory: URL, indexDirectory: URL, worker: any VoiceEmbeddingWorker,
        audioDuration: @escaping @Sendable (URL) async throws -> Double = { url in
            let reader = try StreamingAudioReader.open(url)
            return Double(reader.totalFrames) / StreamingAudioReader.sampleRate
        }
    ) throws {
        index = try LocalVoiceSearchIndex(directory: directory, indexDirectory: indexDirectory)
        self.worker = worker
        self.audioDuration = audioDuration
    }

    private func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    func build(meetingID: UUID, progress: @escaping @Sendable (VoiceSearchBuildProgress) -> Void = { _ in })
        async throws -> Int
    {
        let entry = try await background { [index] in try index.meeting(meetingID) }
        guard !entry.audioFiles.isEmpty else { throw ServiceError("This meeting has no audio to index.") }
        var indexed = 0
        for filename in entry.audioFiles {
            try Task.checkCancellation()
            let (audio, revision, fingerprint, duration) = try await background { [index, audioDuration] in
                let (audio, _) = try index.source(meetingID: meetingID, audioFilename: filename)
                let (revision, fingerprint) = try VoiceSearchArtifacts.sourceRevision(audio)
                let duration = try await audioDuration(audio)
                guard duration.isFinite, duration >= 0.25, duration < 1_000_000_000_000 else {
                    throw ServiceError("Voice search needs at least a quarter second of audio.")
                }
                return (audio, revision, fingerprint, duration)
            }
            let total = Int(ceil(duration / 30))
            progress(.init(meetingID: meetingID, audioFilename: filename, completedClips: 0, totalClips: total))
            for clip in 0..<total {
                try Task.checkCancellation()
                let nominalStart = Double(clip) * 30
                // Cover a very short tail with an overlapping full window; the model
                // cannot process a standalone range shorter than a quarter second.
                let start = duration - nominalStart < 0.25 ? max(0, duration - 30) : nominalStart
                let length = min(30, duration - start)
                let reused = try await background { [index] in
                    try index.reuse(
                        meetingID: meetingID, audioFilename: filename, revision: revision,
                        start: start, duration: length, fingerprint: fingerprint)
                }
                if reused {
                    indexed += 1
                    progress(
                        .init(
                            meetingID: meetingID, audioFilename: filename, completedClips: clip + 1, totalClips: total))
                    continue
                }
                let response = try await worker.embed(audio: audio, start: start, duration: length)
                guard response.vectors.count == 1 else { throw SearchProviderError.invalidResponse }
                let artifact = VoiceSearchArtifact(
                    meetingID: meetingID, audioFilename: filename,
                    sourceRevision: revision, start: start, duration: length, space: VoiceEmbeddingSpace(response),
                    vector: response.vectors[0])
                try await background { [index] in
                    try Task.checkCancellation()
                    guard try VoiceSourceFingerprint.read(audio) == fingerprint else {
                        throw ServiceError("The audio changed while it was being indexed. Build the voice index again.")
                    }
                    try index.persist(artifact, fingerprint: fingerprint)
                }
                indexed += 1
                progress(
                    .init(meetingID: meetingID, audioFilename: filename, completedClips: clip + 1, totalClips: total))
            }
        }
        return indexed
    }
    func rebuildIndex() async throws -> VoiceSearchIndexReport {
        try await background { [index] in try index.rebuild() }
    }
    func remove(meetingID: UUID) async throws {
        try await background { [index] in try index.remove(meetingID: meetingID) }
    }
    func shutdown() async { await worker.shutdown() }

    func search(_ request: ProviderSearchRequest) -> AsyncThrowingStream<ProviderResult<ProviderSearchSnapshot>, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                do {
                    guard request.mode == .voice else { throw SearchProviderError.unsupportedMode }
                    try Task.checkCancellation()
                    let started = Date()
                    let response = try await worker.embed(texts: [request.query])
                    guard VoiceEmbeddingSpace(response) == .clsp, response.vectors.count == 1 else {
                        throw SearchProviderError.invalidResponse
                    }
                    var sequence = 0
                    try index.search(vector: response.vectors[0], request: request) { results, total, final in
                        try Task.checkCancellation()
                        let cursor = request.after + Int64(results.count)
                        continuation.yield(
                            .init(
                                value: .init(
                                    requestID: request.id, providerID: Self.id,
                                    sequence: sequence, results: results, total: final ? total : nil,
                                    nextCursor: final && cursor < Int64(total) ? cursor : nil, isFinal: final),
                                dataFlow: .init(
                                    location: .local, targetID: Self.id, targetName: descriptor.name,
                                    startedAt: started, endedAt: Date(), bodies: ["Search query"],
                                    purpose: "Search local audio embeddings")))
                        sequence += 1
                    }
                    continuation.finish()
                }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
