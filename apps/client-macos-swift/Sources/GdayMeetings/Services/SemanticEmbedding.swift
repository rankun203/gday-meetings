import CoreML
import Foundation
import Tokenizers

enum SemanticModelID: String, Codable, CaseIterable, Sendable, Identifiable {
    case granite97M, granite311M
    var id: String { rawValue }
    var localID: LocalModelID { self == .granite97M ? .granite97M : .granite311M }
    var title: String { LocalModelRegistry.descriptor(localID).title }
    var dimensions: Int { self == .granite97M ? 384 : 768 }
    var maximumTokens: Int { 512 }
    var queryTokens: Int { 128 }
    var paddingToken: Int { self == .granite97M ? 179935 : 0 }
    var space: String { rawValue + ":mixed-fp16-v1:cls:128-512:l2:windows-v1" }
    func inputTokens(isQuery: Bool, tokenCount: Int) -> Int {
        isQuery && tokenCount <= queryTokens ? queryTokens : maximumTokens
    }
    func formatQuery(_ query: String) -> String { query }
    func formatPassage(_ passage: String) -> String { passage }
}

protocol SemanticEmbedding: Sendable {
    var modelID: SemanticModelID { get }
    func prepare() async throws
    func embed(_ text: String, isQuery: Bool) async throws -> [Double]
    func passageParts(_ text: String) async throws -> [String]
    func unload() async
}

/// Core ML and tokenization run on this actor, never on the main actor.
actor CoreMLSemanticEmbedding: SemanticEmbedding {
    nonisolated let modelID: SemanticModelID
    enum Usage: Sendable { case query, indexing }
    private let usage: Usage
    private let manager: LocalModelManager
    private var lease: LocalModelLease?
    private var tokenizer: (any Tokenizer)?
    private var generation = UUID()
    private var preparation: Task<(LocalModelLease, any Tokenizer), Error>?
    private var passageModel: MLModel?
    private var passagePreparation: Task<MLModel, Error>?

    init(modelID: SemanticModelID, manager: LocalModelManager, usage: Usage = .query) {
        self.usage = usage
        self.modelID = modelID
        self.manager = manager
    }

    func prepare() async throws {
        try Task.checkCancellation()
        if lease != nil { return }
        if preparation == nil {
            preparation = Task { [manager, modelID, usage] in
                let acquired = try await manager.acquireInstalled(
                    id: modelID.localID,
                    semanticFunction: usage == .indexing ? "passage512" : nil,
                    priority: usage == .indexing ? .maintenance : .interactive)
                do {
                    let tokenizer = try await AutoTokenizer.from(modelFolder: acquired.directory)
                    guard let model = acquired.models["SemanticEncoder"] else { throw LocalModelError.unavailable }
                    // Prepare the first execution plan while search reports its loading state.
                    try await ProcessingCoordinator.shared.withPermit(
                        for: .inference,
                        priority: usage == .indexing ? .maintenance : .interactive
                    ) {
                        _ = try await model.prediction(
                            from: Self.features(
                                ids: tokenizer.encode(text: "Search"),
                                tokens: usage == .indexing ? modelID.maximumTokens : modelID.queryTokens,
                                paddingToken: modelID.paddingToken))
                    }
                    try Task.checkCancellation()
                    return (acquired, tokenizer)
                }
                catch {
                    await manager.release(acquired)
                    throw error
                }
            }
        }
        let request = generation
        let pending = preparation!
        do {
            let resources = try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: {
                pending.cancel()
            }
            guard generation == request else { throw CancellationError() }
            lease = resources.0
            tokenizer = resources.1
            preparation = nil
            try Task.checkCancellation()
        }
        catch {
            if generation == request { preparation = nil }
            throw error
        }
    }

    func unload() async {
        generation = UUID()
        let pending = preparation
        let held = lease
        preparation = nil
        lease = nil
        tokenizer = nil
        passageModel = nil
        let pendingPassage = passagePreparation
        pendingPassage?.cancel()
        passagePreparation = nil
        _ = try? await pendingPassage?.value
        pending?.cancel()
        if let pending, let resources = try? await pending.value { await manager.release(resources.0) }
        if let held { await manager.release(held) }
    }

    deinit {
        let pendingPassage = passagePreparation
        pendingPassage?.cancel()
        let held = lease
        let pending = preparation
        pending?.cancel()
        let manager = manager
        Task {
            _ = try? await pendingPassage?.value
            if let pending, let resources = try? await pending.value { await manager.release(resources.0) }
            if let held { await manager.release(held) }
        }
    }

    func passageParts(_ text: String) async throws -> [String] {
        try await prepare()
        guard let tokenizer else { throw LocalModelError.unavailable }
        if tokenizer.encode(text: modelID.formatPassage(text)).count <= modelID.maximumTokens { return [text] }
        // Split the original text, not decoded token pieces, preserving all words.
        let characters = Array(text)
        guard characters.count > 1 else { throw SearchProviderError.invalidResponse }
        let midpoint = characters.count / 2
        let left = try await passageParts(String(characters[..<midpoint]))
        let right = try await passageParts(String(characters[midpoint...]))
        return left + right
    }

    func embed(_ text: String, isQuery: Bool) async throws -> [Double] {
        try await prepare()
        guard let tokenizer else { throw LocalModelError.unavailable }
        let formatted = isQuery ? modelID.formatQuery(text) : modelID.formatPassage(text)
        let ids = tokenizer.encode(text: formatted)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError("Enter text to search.")
        }
        guard ids.count <= modelID.maximumTokens else {
            throw ServiceError("This query is too long for the selected model. Shorten it and try again.")
        }
        let tokens = modelID.inputTokens(isQuery: isQuery, tokenCount: ids.count)
        let model = try await encoder(shortQuery: tokens == modelID.queryTokens)
        try Task.checkCancellation()
        let modelID = modelID
        let vector: [Double] = try await ProcessingCoordinator.shared.withPermit(
            for: .inference,
            priority: usage == .indexing ? .maintenance : .interactive
        ) {
            let result = try await model.prediction(
                from: Self.features(
                    ids: ids, tokens: tokens, paddingToken: modelID.paddingToken))
            guard let output = result.featureValue(for: "embedding")?.multiArrayValue,
                output.count == modelID.dimensions
            else { throw SearchProviderError.invalidResponse }
            let vector = (0..<output.count).map { output[$0].doubleValue }
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            guard vector.allSatisfy(\.isFinite), norm.isFinite, norm > 0 else {
                throw SearchProviderError.invalidResponse
            }
            return vector.map { $0 / norm }
        }

        try Task.checkCancellation()
        return vector
    }

    nonisolated private static func features(ids: [Int], tokens: Int, paddingToken: Int) throws
        -> MLDictionaryFeatureProvider
    {
        let input = try MLMultiArray(shape: [1, NSNumber(value: tokens)], dataType: .int32)
        let mask = try MLMultiArray(shape: input.shape, dataType: .int32)
        for index in 0..<tokens {
            input[index] = NSNumber(value: index < ids.count ? ids[index] : paddingToken)
            mask[index] = NSNumber(value: index < ids.count ? 1 : 0)
        }
        return try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: input), "attention_mask": MLFeatureValue(multiArray: mask),
        ])
    }

    private func encoder(shortQuery: Bool) async throws -> MLModel {
        guard let lease else { throw LocalModelError.unavailable }
        if shortQuery || usage == .indexing {
            guard let model = lease.models["SemanticEncoder"] else { throw LocalModelError.unavailable }
            return model
        }
        if let passageModel { return passageModel }
        if passagePreparation == nil {
            passagePreparation = Task { [manager] in
                // The additional long-query plan belongs to this query worker.
                try await manager.prepareSemanticPassage(for: lease)
            }
        }
        let request = generation
        do {
            let model = try await passagePreparation!.value
            guard generation == request else { throw CancellationError() }
            passageModel = model
            passagePreparation = nil
            try Task.checkCancellation()
            return model
        }
        catch {
            if generation == request { passagePreparation = nil }
            throw error
        }
    }
}

struct SpeakerMatchScore: Equatable, Sendable {
    let similarity: Double
    let matchedPeople: Int
    let identifiedPeople: Int
    let bonus: Double
    var total: Double { similarity + bonus }
    init(similarity: Double, identified: Set<UUID>, speakers: Set<UUID>, boost: Double) {
        self.similarity = similarity
        identifiedPeople = identified.count
        matchedPeople = identified.intersection(speakers).count
        let bounded = boost.isFinite ? min(0.2, max(0, boost)) : 0.1
        bonus = identified.isEmpty ? 0 : bounded * Double(matchedPeople) / Double(identified.count)
    }
    var description: String {
        String(
            format: "Content %.4f · Speakers %d/%d · Bonus %.4f · Score %.4f", similarity, matchedPeople,
            identifiedPeople, bonus, total)
    }
}
