import CoreML
import Foundation

/// Owns one model lease and serializes prediction and preprocessing off the main actor.
actor CLSPCoreMLWorker: VoiceEmbeddingWorker {
    private final class Resources: @unchecked Sendable {
        let lease: LocalModelLease
        let tokenizer: CLSPTokenizer
        let frontend: CLSPAudioFrontend
        private let manager: LocalModelManager

        init(lease: LocalModelLease, tokenizer: CLSPTokenizer, frontend: CLSPAudioFrontend, manager: LocalModelManager)
        {
            self.lease = lease
            self.tokenizer = tokenizer
            self.frontend = frontend
            self.manager = manager
        }

        deinit {
            // Explicit shutdown and idle unloading await release. This is the ownership
            // fallback when a provider disappears without either path; release is idempotent.
            let manager = manager
            let lease = lease
            Task { @MainActor in manager.release(lease) }
        }
    }
    private let manager: LocalModelManager
    private var preparation: (id: UUID, task: Task<Resources, Error>)?
    private var shutdownTask: Task<Void, Never>?
    private var closed = false
    private let idleTimeout: Duration
    private var activeRequests = 0
    private var idleTask: Task<Void, Never>?
    private var releasing: (id: UUID, task: Task<Void, Never>)?

    @MainActor
    init() {
        idleTimeout = .seconds(30)
        manager = .shared
    }

    init(manager: LocalModelManager, idleTimeout: Duration = .seconds(30)) {
        self.idleTimeout = idleTimeout
        self.manager = manager
    }

    deinit { idleTask?.cancel() }

    private func resources() async throws -> Resources {
        if let releasing { await releasing.task.value }
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        if preparation == nil {
            preparation = (
                UUID(),
                Task { [manager] in
                    let lease = try await manager.acquireInstalled(id: .clsp)
                    do {
                        let tokenizer = try await CLSPTokenizer(directory: lease.directory)
                        return try Resources(
                            lease: lease, tokenizer: tokenizer, frontend: CLSPAudioFrontend(), manager: manager)
                    }
                    catch {
                        await manager.release(lease)
                        throw error
                    }
                }
            )
        }
        let request = preparation!
        let result: Resources
        do { result = try await request.task.value }
        catch {
            if !closed, preparation?.id == request.id { preparation = nil }
            throw error
        }
        // A cancelled caller must not discard a successfully acquired shared lease.
        // Shutdown owns its release, including when it races initial preparation.
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }

    func embed(texts: [String]) async throws -> LocalSearchEmbeddingResponse {
        guard (1...64).contains(texts.count),
            texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4096 })
        else {
            throw ServiceError("Enter between 1 and 64 voice descriptions, each containing 1–4096 characters.")
        }
        try beginRequest()
        defer { finishRequest() }
        let resources = try await resources()
        guard let model = resources.lease.models["CLSPText"] else { throw LocalModelError.unavailable }
        var vectors: [[Double]] = []
        for text in texts {
            try Task.checkCancellation()
            let tokens = try resources.tokenizer.encode(text)
            let ids = try Self.integers(tokens.ids, shape: [1, NSNumber(value: tokens.ids.count)])
            let mask = try Self.integers(tokens.attentionMask, shape: ids.shape)
            vectors.append(try Self.predict(model, inputs: ["input_ids": ids, "attention_mask": mask]))
            try Task.checkCancellation()
        }
        return Self.response(vectors)
    }

    func embed(audio: URL, start: Double, duration: Double) async throws -> LocalSearchEmbeddingResponse {
        guard start.isFinite, start >= 0, duration.isFinite, duration >= 0.25, duration <= 30 else {
            throw ServiceError("Choose an audio range between 0.25 and 30 seconds.")
        }
        try beginRequest()
        defer { finishRequest() }
        let resources = try await resources()
        guard let model = resources.lease.models["CLSPAudio"] else { throw LocalModelError.unavailable }
        let samples = try CLSPAudioLoader.load(url: audio, start: start, duration: duration)
        let features = try resources.frontend.features(samples)
        try Task.checkCancellation()
        let input = try MLMultiArray(
            shape: [1, NSNumber(value: features.frameCount), 128], dataType: .float32)
        features.values.withUnsafeBufferPointer {
            input.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count)
        }
        let lengths = try Self.integers([Int32(features.frameCount)], shape: [1])
        let vector = try Self.predict(model, inputs: ["features": input, "lengths": lengths])
        try Task.checkCancellation()
        return Self.response([vector])
    }

    private func beginRequest() throws {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        idleTask?.cancel()
        idleTask = nil
        activeRequests += 1
    }

    private func finishRequest() {
        activeRequests -= 1
        guard activeRequests == 0, !closed, preparation != nil else { return }
        idleTask = Task { [weak self, idleTimeout] in
            do { try await Task.sleep(for: idleTimeout) }
            catch { return }
            await self?.unloadIdleResources()
        }
    }

    private func unloadIdleResources() async {
        guard !Task.isCancelled, activeRequests == 0, !closed, let pending = preparation else { return }
        preparation = nil
        idleTask = nil
        let id = UUID()
        let task = Task { [manager] in
            if let resources = try? await pending.task.value { await manager.release(resources.lease) }
        }
        releasing = (id, task)
        await task.value
        if releasing?.id == id { releasing = nil }
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        closed = true
        idleTask?.cancel()
        idleTask = nil
        let release = releasing?.task
        let pending = preparation?.task
        let task = Task { [manager] in
            await release?.value
            if let pending, let resources = try? await pending.value {
                await manager.release(resources.lease)
            }
        }
        shutdownTask = task
        await task.value
        preparation = nil
    }

    private static func integers(_ values: [Int32], shape: [NSNumber]) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape, dataType: .int32)
        values.withUnsafeBufferPointer {
            result.dataPointer.assumingMemoryBound(to: Int32.self).update(from: $0.baseAddress!, count: $0.count)
        }
        return result
    }

    private static func predict(_ model: MLModel, inputs: [String: MLMultiArray]) throws -> [Double] {
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let output = prediction.featureValue(for: "embedding")?.multiArrayValue, output.count == 512 else {
            throw SearchProviderError.invalidResponse
        }
        return try normalizedEmbedding((0..<512).map { output[$0].doubleValue })
    }

    static func normalizedEmbedding(_ values: [Double]) throws -> [Double] {
        guard values.count == 512 else { throw SearchProviderError.invalidResponse }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard values.allSatisfy(\.isFinite), norm.isFinite, norm > 0 else {
            throw SearchProviderError.invalidResponse
        }
        return values.map { $0 / norm }
    }

    private static func response(_ vectors: [[Double]]) -> LocalSearchEmbeddingResponse {
        let space = VoiceEmbeddingSpace.clsp
        return .init(
            model: space.model, revision: space.revision, preprocessing: space.preprocessing,
            dimension: space.dimension, normalization: space.normalization, vectors: vectors)
    }
}
