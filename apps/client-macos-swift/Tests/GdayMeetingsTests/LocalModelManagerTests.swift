import CoreML
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import GdayMeetings

private actor ModelPreparationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private final class ModelDownloadObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func append(_ value: Int64) { lock.withLock { values.append(value) } }
    var snapshot: [Int64] { lock.withLock { values } }
}

@MainActor struct LocalModelManagerTests {
    @Test func throttledDownloadReportsPartialBytesAndCleansUpOnCancellation() async throws {
        let fixture = try HTTPFixture { _ in
            .init(bodyChunks: Array(repeating: Data(repeating: 7, count: 65_536), count: 128), chunkDelay: 0.025)
        }
        try await fixture.start()
        defer { fixture.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: fixture.origin + "/model"))
        let expected = Int64(8 * 1024 * 1024)
        let observations = ModelDownloadObservations()
        let (file, response) = try await LocalModelDownload.download(from: url, temporaryDirectory: root) {
            observations.append($0)
        }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: file).count == Int(expected))
        let values = observations.snapshot
        #expect(Set(values.filter { $0 > 0 && $0 < expected }).count > 2)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        try FileManager.default.removeItem(at: file)

        let cancelledProgress = ModelDownloadObservations()
        let transfer = Task {
            try await LocalModelDownload.download(from: url, temporaryDirectory: root) {
                cancelledProgress.append($0)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while cancelledProgress.snapshot.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(cancelledProgress.snapshot.contains { $0 > 0 && $0 < expected })
        transfer.cancel()
        await #expect(throws: CancellationError.self) { _ = try await transfer.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let (retried, _) = try await LocalModelDownload.download(from: url, temporaryDirectory: root) { _ in }
        #expect(try Data(contentsOf: retried).count == Int(expected))
        try FileManager.default.removeItem(at: retried)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private let bytes = Data("synthetic model".utf8)
    private func descriptor(_ id: LocalModelID) -> LocalModelDescriptor {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(
            id: id, title: "Synthetic", repository: "synthetic/model", revision: "pinned",
            assets: [
                .init(
                    path: "Model.mlmodelc/data", remotePath: "Model.mlmodelc/data", bytes: Int64(bytes.count),
                    digest: digest)
            ], modelNames: ["Model"])
    }
    private func writeModel(_ directory: URL) throws {
        let file = directory.appendingPathComponent("Model.mlmodelc/data")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
    }
    private func settle(_ manager: LocalModelManager, id: LocalModelID) async throws {
        for _ in 0..<100 {
            if ![LocalModelPhase.downloading, .verifying, .preparing].contains(manager.state(for: id).phase) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Model task did not settle")
    }

    @Test func copiedFoldersRequireVerificationAndLeasesPreventRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let id = LocalModelID.voiceEmbedding
        try writeModel(manager.modelDirectory(for: id))
        await manager.refresh()
        #expect(manager.state(for: id).phase == .unverified)
        await #expect(throws: (any Error).self) { _ = try await manager.acquire(id) }
        manager.verify(id)
        try await settle(manager, id: id)
        #expect(manager.state(for: id).phase == .ready)
        let lease = try await manager.acquire(id)
        #expect(manager.state(for: id).inUse == 1)
        await #expect(throws: (any Error).self) { try await manager.remove(id) }
        manager.release(lease)
        manager.release(lease)
        #expect(manager.state(for: id).inUse == 0)
        try await manager.remove(id)
        #expect(manager.state(for: id).phase == .missing)
    }

    @Test func badHashCannotBecomeReadyAndCancellationCanRetryVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(
            root: root, descriptor: descriptor,
            preparer: { _, _ in
                try await Task.sleep(for: .milliseconds(150))
                return [:]
            })
        let id = LocalModelID.voiceEmbedding
        try writeModel(manager.modelDirectory(for: id))
        let file = manager.modelDirectory(for: id).appendingPathComponent("Model.mlmodelc/data")
        try Data(repeating: 1, count: bytes.count).write(to: file)
        manager.verify(id)
        try await settle(manager, id: id)
        #expect(manager.state(for: id).phase == .failed)
        try writeModel(manager.modelDirectory(for: id))
        manager.verify(id)
        manager.cancel(id)
        try await settle(manager, id: id)
        #expect(manager.state(for: id).phase == .cancelled)
        manager.verify(id)
        try await settle(manager, id: id)
        #expect(manager.state(for: id).phase == .ready)
        // A receipt requests fresh verification and preparation after a restart.
        let reopened = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let restartedLease = try await reopened.acquire(id)
        reopened.release(restartedLease)
        #expect(reopened.state(for: id).phase == .ready)
        try Data(repeating: 2, count: bytes.count).write(to: file)
        await reopened.refresh()
        try await settle(reopened, id: id)
        #expect(reopened.state(for: id).phase == .failed)
    }

    @Test func allPresetsPinTheRuntimeLayoutAndRequiredSharedAssets() throws {
        for id in LocalModelID.allCases {
            let descriptor = LocalModelRegistry.descriptor(id)
            #expect(!descriptor.assets.isEmpty)
            #expect(Set(descriptor.assets.map(\.path)).count == descriptor.assets.count)
            #expect(descriptor.assets.allSatisfy { $0.bytes > 0 && [40, 64].contains($0.digest.count) })
            if let preset = id.nemotronPreset {
                let config = try #require(Nemotron3Config.preset(named: preset))
                #expect(descriptor.modelNames == [String(config.modelFileName.dropLast(".mlmodelc".count))])
                #expect(descriptor.inputBufferSeconds == config.latencySeconds)
                #expect(descriptor.assets.contains { $0.path == "learnable_sil_emb.bin" })
                #expect(descriptor.assets.contains { $0.path == "pre_encode_proj_t.bin" } == config.splitGraph)
                #expect(
                    descriptor.assets.filter { $0.path.contains(".mlmodelc/") }.allSatisfy {
                        $0.remotePath == config.hubSubdirectory + "/" + $0.path
                    })
            }
        }
        let community = LocalModelRegistry.descriptor(.community1)
        let embeddings = LocalModelRegistry.descriptor(.voiceEmbedding)
        #expect(Set(embeddings.assets).isSubset(of: Set(community.assets)))
    }

    @Test func verifiedSharedFilesSurviveRemovingAnotherInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let asset = try #require(descriptor(.voiceEmbedding).assets.first)
        let object = root.appendingPathComponent("objects/" + asset.digest)
        try FileManager.default.createDirectory(
            at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: object)
        for id in [LocalModelID.community1, .voiceEmbedding] {
            manager.download(id)
            try await settle(manager, id: id)
            #expect(manager.state(for: id).phase == .ready)
        }
        try await manager.remove(.community1)
        #expect(FileManager.default.fileExists(atPath: object.path))
        let lease = try await manager.acquire(.voiceEmbedding)
        manager.release(lease)
        try await manager.remove(.voiceEmbedding)
        #expect(!FileManager.default.fileExists(atPath: object.path))
    }

    @Test func manuallyVerifiedCommunityProvidesEmbeddingFilesWithoutDownloading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let source = manager.modelDirectory(for: .community1)
        try writeModel(source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: source.appendingPathComponent("Model.mlmodelc/data").path)
        manager.verify(.community1)
        try await settle(manager, id: .community1)
        #expect(manager.state(for: .voiceEmbedding).phase == .ready)
        let reopened = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let lease = try await reopened.acquire(.voiceEmbedding)
        try await reopened.remove(.community1)
        #expect(
            FileManager.default.fileExists(atPath: lease.directory.appendingPathComponent("Model.mlmodelc/data").path))
        reopened.release(lease)
    }

    @Test func concurrentLeasesPrepareSeparateCoreMLInstances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = ModelPreparationCounter()
        let manager = LocalModelManager(
            root: root, descriptor: descriptor,
            preparer: { _, _ in
                await counter.increment()
                return [:]
            })
        try writeModel(manager.modelDirectory(for: .voiceEmbedding))
        manager.verify(.voiceEmbedding)
        try await settle(manager, id: .voiceEmbedding)
        let first = try await manager.acquire(.voiceEmbedding)
        let second = try await manager.acquire(.voiceEmbedding)
        #expect(await counter.count == 3)
        #expect(manager.state(for: .voiceEmbedding).inUse == 2)
        manager.release(first)
        manager.release(second)
    }
}
