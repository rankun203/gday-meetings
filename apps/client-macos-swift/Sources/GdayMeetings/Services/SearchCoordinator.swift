import Foundation

struct SearchProgress: Sendable {
    let requestID: UUID
    let results: [FusedSearchResult]
    let failures: [UUID: String]
    let isFinal: Bool
}

/// Independent providers can publish at different speeds. Each event replaces that
/// provider's results; failures remain visible while successful providers continue.
struct SearchCoordinator: Sendable {
    let providers: [any SearchProvider]

    func search(_ request: ProviderSearchRequest) -> AsyncThrowingStream<SearchProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let selected = providers.filter { provider in
                    request.mode == .fusion
                        ? !provider.descriptor.modes.intersection([.text, .voice]).isEmpty
                        : provider.descriptor.modes.contains(request.mode)
                }
                guard !selected.isEmpty else {
                    continuation.finish(throwing: SearchProviderError.unsupportedMode)
                    return
                }
                if request.mode == .fusion {
                    let modes = selected.reduce(into: Set<SearchMode>()) { $0.formUnion($1.descriptor.modes) }
                    guard modes.contains(.text), modes.contains(.voice) else {
                        continuation.finish(throwing: SearchProviderError.unsupportedMode)
                        return
                    }
                }
                let ids = selected.map { $0.descriptor.id }
                guard Set(ids).count == ids.count else {
                    continuation.finish(throwing: SearchProviderError.invalidResponse)
                    return
                }
                let collector = SearchProgressCollector(request: request, ids: ids, continuation: continuation)
                await withTaskGroup(of: Void.self) { group in
                    for provider in selected {
                        group.addTask {
                            var child = request
                            child.mode =
                                provider.descriptor.modes.contains(request.mode)
                                ? request.mode
                                : (provider.descriptor.modes.contains(.voice) ? .voice : .text)
                            child.ranked = true
                            do {
                                var finished = false
                                for try await event in provider.search(child) {
                                    try Task.checkCancellation()
                                    guard event.value.providerID == provider.descriptor.id,
                                        event.value.requestID == request.id
                                    else { throw SearchProviderError.invalidResponse }
                                    guard await collector.receive(event.value) else {
                                        throw SearchProviderError.invalidResponse
                                    }
                                    if event.value.isFinal {
                                        finished = true
                                        break
                                    }
                                }
                                if !finished { throw SearchProviderError.incompleteResponse }
                            }
                            catch {
                                if !Task.isCancelled {
                                    await collector.failed(
                                        provider.descriptor.id,
                                        message: "\(provider.descriptor.name): \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                }
                else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private actor SearchProgressCollector {
    let request: ProviderSearchRequest
    let ids: Set<UUID>
    let continuation: AsyncThrowingStream<SearchProgress, Error>.Continuation
    var fusion: ReciprocalRankFusion
    var failures: [UUID: String] = [:]
    var completed: Set<UUID> = []

    init(
        request: ProviderSearchRequest, ids: [UUID],
        continuation: AsyncThrowingStream<SearchProgress, Error>.Continuation
    ) {
        self.request = request
        self.ids = Set(ids)
        self.continuation = continuation
        fusion = .init(requestID: request.id, weights: Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) }))
    }
    func receive(_ snapshot: ProviderSearchSnapshot) -> Bool {
        guard fusion.accept(snapshot) else { return false }
        if snapshot.isFinal { completed.insert(snapshot.providerID) }
        publish()
        return true
    }
    func failed(_ provider: UUID, message: String) {
        failures[provider] = message
        completed.insert(provider)
        publish()
    }
    private func publish() {
        continuation.yield(
            .init(
                requestID: request.id, results: fusion.results(limit: request.limit),
                failures: failures, isFinal: completed == ids))
    }
}
