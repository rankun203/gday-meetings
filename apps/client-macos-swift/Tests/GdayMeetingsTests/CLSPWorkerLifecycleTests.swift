import Combine
import CoreML
import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

private final class CLSPPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let startSignal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func waitUntilStarted() async throws {
        for await _ in startSignal.stream { return }
        try Task.checkCancellation()
    }
    var calls: Int { lock.withLock { count } }
    func enter() async {
        await withCheckedContinuation { next in
            lock.withLock {
                count += 1
                if count == 2 {
                    startSignal.continuation.yield(())
                    startSignal.continuation.finish()
                }
                if count == 2 && !released {
                    continuation = next
                }
                else {
                    next.resume()
                }
            }
        }
    }
    func release() {
        let next = lock.withLock {
            released = true
            let next = continuation
            continuation = nil
            return next
        }
        next?.resume()
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor struct CLSPWorkerLifecycleTests {
    private func manager(root: URL, gate: CLSPPreparationGate? = nil, tokenizer: Bool = true) throws
        -> LocalModelManager
    {
        let bytes = Data("synthetic".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manager = LocalModelManager(
            root: root,
            descriptor: { id in
                .init(
                    id: id, title: "Synthetic", repository: "synthetic/local", revision: "fixture",
                    assets: [
                        .init(path: "fixture.bin", remotePath: "fixture.bin", bytes: Int64(bytes.count), digest: digest)
                    ],
                    modelNames: [])
            },
            preparer: { _, _ in
                await gate?.enter()
                return [:]
            })
        let directory = manager.modelDirectory(for: .clsp)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("fixture.bin"))
        if tokenizer {
            let config: [String: Any] = ["tokenizer_class": "RobertaTokenizer", "model_max_length": 512]
            let data: [String: Any] = [
                "version": "1.0", "added_tokens": [],
                "model": [
                    "type": "BPE", "vocab": ["<s>": 0, "<pad>": 1, "</s>": 2, "<unk>": 3, "x": 4], "merges": [],
                ],
                "post_processor": [
                    "type": "RobertaProcessing", "sep": ["</s>", 2], "cls": ["<s>", 0], "trim_offsets": true,
                    "add_prefix_space": false,
                ],
            ]
            try JSONSerialization.data(withJSONObject: config).write(
                to: directory.appendingPathComponent("tokenizer_config.json"))
            try JSONSerialization.data(withJSONObject: data).write(
                to: directory.appendingPathComponent("tokenizer.json"))
            try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        }
        return manager
    }
    @Test func preparationPublishesReadyThroughBothObservablePublishers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try manager(root: root)
        var phases: [LocalModelPhase] = []
        var objectChanges = 0
        let stateSubscription = manager.$states.sink { states in
            if let phase = states[.clsp]?.phase { phases.append(phase) }
        }
        let objectSubscription = manager.objectWillChange.sink { objectChanges += 1 }
        defer {
            stateSubscription.cancel()
            objectSubscription.cancel()
        }
        manager.verify(.clsp)
        let lease = try await manager.acquireInstalled(id: .clsp)
        #expect(manager.state(for: .clsp).phase == .ready)
        #expect(phases.contains(.preparing))
        #expect(phases.last == .ready)
        #expect(objectChanges == phases.count - 1)
        manager.release(lease)
    }

    @Test func shutdownJoinsPreparationAndRejectsQueuedEmbedding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CLSPPreparationGate()
        defer { gate.release() }
        let manager = try manager(root: root, gate: gate)
        let worker = CLSPCoreMLWorker(manager: manager)
        let embedding = Task { try await worker.embed(texts: ["x"]) }
        try await gate.waitUntilStarted()
        #expect(manager.state(for: .clsp).inUse == 1)
        var firstFinished = false
        var secondFinished = false
        let first = Task {
            await worker.shutdown()
            firstFinished = true
        }
        let second = Task {
            await worker.shutdown()
            secondFinished = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!firstFinished && !secondFinished)
        gate.release()
        await first.value
        await second.value
        await #expect(throws: CancellationError.self) { try await embedding.value }
        await #expect(throws: CancellationError.self) { try await worker.embed(texts: ["x"]) }
        #expect(manager.state(for: .clsp).inUse == 0)
    }
    @Test func cancelledCallerDoesNotLoseSharedLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CLSPPreparationGate()
        defer { gate.release() }
        let manager = try manager(root: root, gate: gate)
        let worker = CLSPCoreMLWorker(manager: manager)
        let cancelled = Task { try await worker.embed(texts: ["x"]) }
        try await gate.waitUntilStarted()
        let other = Task { try await worker.embed(texts: ["x"]) }
        cancelled.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        // The synthetic lease has no encoder model; resource preparation itself succeeds.
        await #expect(throws: LocalModelError.self) { try await other.value }
        #expect(manager.state(for: .clsp).inUse == 1)
        #expect(gate.calls == 2)
        await worker.shutdown()
        #expect(manager.state(for: .clsp).inUse == 0)
    }
    @Test func idleUnloadWaitsForPreparationAndAllowsReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CLSPPreparationGate()
        defer { gate.release() }
        let manager = try manager(root: root, gate: gate)
        let worker = CLSPCoreMLWorker(manager: manager, idleTimeout: .milliseconds(10))
        let embedding = Task { try await worker.embed(texts: ["x"]) }
        try await gate.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(30))
        #expect(manager.state(for: .clsp).inUse == 1)
        gate.release()
        await #expect(throws: LocalModelError.self) { try await embedding.value }
        // The suite time limit cancels this await if the idle release never occurs.
        // Do not make correctness depend on MainActor scheduling within five seconds.
        while manager.state(for: .clsp).inUse != 0 { try await Task.sleep(for: .milliseconds(10)) }
        let calls = gate.calls
        await #expect(throws: LocalModelError.self) { try await worker.embed(texts: ["x"]) }
        #expect(gate.calls > calls)
        await worker.shutdown()
        #expect(manager.state(for: .clsp).inUse == 0)
    }
    @Test func droppingWorkerReleasesLeaseWithoutExplicitShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try manager(root: root)
        var worker: CLSPCoreMLWorker? = CLSPCoreMLWorker(manager: manager, idleTimeout: .seconds(3600))
        weak let weakWorker = worker
        await #expect(throws: LocalModelError.self) { try await worker!.embed(texts: ["x"]) }
        #expect(manager.state(for: .clsp).inUse == 1)
        worker = nil
        #expect(weakWorker == nil)
        while manager.state(for: .clsp).inUse != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(manager.state(for: .clsp).inUse == 0)
    }

    @Test func tokenizerFailureReleasesLeaseAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try manager(root: root, tokenizer: false)
        let worker = CLSPCoreMLWorker(manager: manager)
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) { try await worker.embed(texts: ["x"]) }
            #expect(manager.state(for: .clsp).inUse == 0)
        }
        await worker.shutdown()
        #expect(manager.state(for: .clsp).inUse == 0)
    }
    @Test func invalidRequestsDoNotPrepareModelsAndInvalidVectorsAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CLSPPreparationGate()
        let manager = try manager(root: root, gate: gate)
        let worker = CLSPCoreMLWorker(manager: manager)
        await #expect(throws: (any Error).self) { try await worker.embed(texts: [" "]) }
        await #expect(throws: (any Error).self) { try await worker.embed(audio: root, start: 0, duration: .infinity) }
        #expect(gate.calls == 0)
        for values in [
            [Double](), Array(repeating: 0, count: 512), Array(repeating: .nan, count: 512),
            Array(repeating: .infinity, count: 512),
        ] {
            #expect(throws: SearchProviderError.self) { try CLSPCoreMLWorker.normalizedEmbedding(values) }
        }
        let vector = try CLSPCoreMLWorker.normalizedEmbedding(Array(repeating: 2, count: 512))
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 1e-12)
        await worker.shutdown()
    }
}
