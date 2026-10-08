import CoreML
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import GdayMeetings

private actor ModelPreparationCounter {
    private(set) var count = 0
    private(set) var requests: [[String]] = []
    func increment() { count += 1 }
    func record(_ names: [String]) {
        count += 1
        requests.append(names)
    }
}

private final class ModelDownloadObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func append(_ value: Int64) { lock.withLock { values.append(value) } }
    var snapshot: [Int64] { lock.withLock { values } }
}

@MainActor struct LocalModelManagerTests {
    @Test func readinessIgnoresDownloadProgressAndLeases() {
        var state = LocalModelState(phase: .downloading, totalBytes: 100)
        let initial = state.healthIdentity
        for bytes in 1...100 {
            state.completedBytes = Int64(bytes)
            #expect(state.healthIdentity == initial)
        }
        state.totalBytes = 200
        state.inUse = 1
        #expect(state.healthIdentity == initial)
        for phase in [LocalModelPhase.verifying, .preparing, .ready, .cancelled, .failed, .missing, .unverified] {
            let previous = state.healthIdentity
            state.phase = phase
            #expect(state.healthIdentity != previous)
        }
        let previous = state.healthIdentity
        state.message = "Synthetic setup failure."
        #expect(state.healthIdentity != previous)
    }

    @Test func legacyModelsCopyIntoDataFolderWithoutOverwritingExistingModels() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let legacy = fixture.appendingPathComponent("legacy")
        let root = fixture.appendingPathComponent("library/LocalModels")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let data = Data("synthetic model".utf8)
        try data.write(to: legacy.appendingPathComponent("model.bin"))
        let files = LocalModelFiles(root: root)
        try await files.importLegacyStorage(from: legacy)
        #expect(try Data(contentsOf: root.appendingPathComponent("model.bin")) == data)
        #expect(try Data(contentsOf: legacy.appendingPathComponent("model.bin")) == data)
        let replacement = Data("new library model".utf8)
        try replacement.write(to: root.appendingPathComponent("model.bin"))
        try await files.importLegacyStorage(from: legacy)
        #expect(try Data(contentsOf: root.appendingPathComponent("model.bin")) == replacement)
        #expect(
            !(try FileManager.default.contentsOfDirectory(atPath: fixture.appendingPathComponent("library").path))
                .contains { $0.hasPrefix(".local-model-import-") })
    }

    @Test func unavailableDataFolderRejectsModelWritesAndExplicitRootDoesNotImport() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let unavailable = LocalModelManager(root: fixture, storageAvailable: false)
        await #expect(throws: (any Error).self) { try await unavailable.openableDirectory(for: .community1) }
        await unavailable.refresh()
        #expect(unavailable.state(for: .community1).phase == .failed)
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        let isolated = LocalModelManager(root: fixture)
        try await isolated.prepareStorage()
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        try isolated.suspendForLibraryChange()
        await #expect(throws: LocalModelError.self) { try await isolated.openableDirectory(for: .community1) }
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        isolated.resumeAfterLibraryChange()
        let directory = try await isolated.openableDirectory(for: .community1)
        #expect(directory.path.hasPrefix(fixture.path + "/"))
    }

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

    @Test func copiedFoldersVerifyAutomaticallyAndLeasesPreventRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let id = LocalModelID.community1
        try writeModel(manager.modelDirectory(for: id))
        await manager.refresh()
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

    @Test func copiedModelCanBeAcquiredWithoutOpeningProviderSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let id = LocalModelID.community1
        try writeModel(manager.modelDirectory(for: id))
        let lease = try await manager.acquire(id)
        #expect(manager.state(for: id).phase == .ready)
        #expect(manager.state(for: id).inUse == 1)
        manager.release(lease)
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
        let id = LocalModelID.community1
        try writeModel(manager.modelDirectory(for: id))
        let file = manager.modelDirectory(for: id).appendingPathComponent("Model.mlmodelc/data")
        try Data(repeating: 1, count: bytes.count).write(to: file)
        await manager.refresh()
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

    @Test func allModelsPinTheirRuntimeLayoutAndRequiredAssets() throws {
        for id in LocalModelID.allCases {
            let descriptor = LocalModelRegistry.descriptor(id)
            #expect(!descriptor.assets.isEmpty)
            #expect(Set(descriptor.assets.map(\.path)).count == descriptor.assets.count)
            #expect(descriptor.assets.allSatisfy { $0.bytes > 0 && [40, 64].contains($0.digest.count) })

        }
        let community = LocalModelRegistry.descriptor(.community1)
        #expect(Set(community.modelNames) == ["Segmentation", "FBank", "Embedding", "PldaRho"])
    }

    @Test func verifiedSharedFilesSurviveRemovingAnotherInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let asset = try #require(descriptor(.granite97M).assets.first)
        let object = root.appendingPathComponent("objects/" + asset.digest)
        try FileManager.default.createDirectory(
            at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: object)
        for id in [LocalModelID.community1, .granite97M] {
            manager.download(id)
            try await settle(manager, id: id)
            #expect(manager.state(for: id).phase == .ready)
        }
        try await manager.remove(.community1)
        #expect(FileManager.default.fileExists(atPath: object.path))
        let lease = try await manager.acquire(.granite97M)
        manager.release(lease)
        try await manager.remove(.granite97M)
        #expect(!FileManager.default.fileExists(atPath: object.path))
    }

    @Test func voiceExtractionLoadsOnlyItsGraphsAndProtectsTheSharedInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = descriptor(.community1)
        fixture.modelNames = ["Segmentation", "FBank", "Embedding", "PldaRho"]
        let manager = LocalModelManager(
            root: root, descriptor: { _ in fixture },
            preparer: { requested, _ in
                #expect(requested.modelNames == ["FBank", "Embedding"])
                return [:]
            })
        try writeModel(manager.modelDirectory(for: .community1))
        let lease = try await manager.acquire(.community1, modelNames: ["FBank", "Embedding"])
        #expect(lease.id == .community1)
        #expect(manager.state(for: .community1).inUse == 1)
        await #expect(throws: LocalModelError.self) { try await manager.remove(.community1) }
        manager.release(lease)
        #expect(manager.state(for: .community1).inUse == 0)
    }

    @Test func retiredEmbeddingFilesMoveIntoCommunityInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root, descriptor: descriptor, preparer: { _, _ in [:] })
        let retired = root.appendingPathComponent("voiceEmbedding")
            .appendingPathComponent(descriptor(.community1).revision)
        try writeModel(retired)
        try await manager.prepareStorage()
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        let lease = try await manager.acquire(.community1)
        #expect(lease.directory == manager.modelDirectory(for: .community1))
        await #expect(throws: LocalModelError.self) { try await manager.remove(.community1) }
        manager.release(lease)
        try await manager.remove(.community1)
        #expect(!(await manager.health(for: .community1)).isReady)
    }

    @Test func concurrentLiveAndRecordedRequestsLoadEachCommunityGraphOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = descriptor(.community1)
        fixture.modelNames = ["Segmentation", "FBank", "Embedding", "PldaRho"]
        let counter = ModelPreparationCounter()
        let manager = LocalModelManager(
            root: root, descriptor: { _ in fixture },
            preparer: { requested, _ in
                await counter.record(requested.modelNames)
                try await Task.sleep(for: .milliseconds(30))
                return [:]
            })
        try writeModel(manager.modelDirectory(for: .community1))
        async let first = manager.acquire(.community1, modelNames: ["FBank", "Embedding"], priority: .capture)
        async let second = manager.acquire(.community1, modelNames: ["FBank", "Embedding"], priority: .capture)
        let (live, voice) = try await (first, second)
        #expect(await counter.requests == [["FBank", "Embedding"]])
        let offline = try await manager.acquire(.community1)
        #expect(await counter.requests == [["FBank", "Embedding"], ["Segmentation", "PldaRho"]])
        manager.release(live)
        manager.release(voice)
        let another = try await manager.acquire(.community1, modelNames: ["FBank", "Embedding"])
        #expect(await counter.count == 2)
        manager.release(offline)
        manager.release(another)
        let reopened = try await manager.acquire(.community1, modelNames: ["FBank", "Embedding"])
        #expect(await counter.count == 3)
        manager.release(reopened)
    }

    @Test func communityLeasesShareResidentGraphsUntilTheLastRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = ModelPreparationCounter()
        let manager = LocalModelManager(
            root: root, descriptor: descriptor,
            preparer: { _, _ in
                await counter.increment()
                return [:]
            })
        try writeModel(manager.modelDirectory(for: .community1))
        manager.verify(.community1)
        try await settle(manager, id: .community1)
        let first = try await manager.acquire(.community1)
        let second = try await manager.acquire(.community1)
        #expect(await counter.count == 2)
        #expect(manager.state(for: .community1).inUse == 2)
        manager.release(first)
        manager.release(second)
        let reopened = try await manager.acquire(.community1)
        #expect(await counter.count == 3)
        manager.release(reopened)
    }
}
