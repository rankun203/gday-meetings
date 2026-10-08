import Combine
import CoreML
import CryptoKit
import Darwin
import Foundation

enum LocalModelPhase: String, Sendable {
    case missing, unverified, downloading, verifying, preparing, ready, cancelled, failed
}

struct LocalModelState: Sendable {
    struct HealthIdentity: Equatable {
        let phase: LocalModelPhase
        let message: String?
    }

    var phase: LocalModelPhase = .missing
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var message: String?
    var inUse = 0
    var progress: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }
    // Download progress and leases do not change model readiness.
    var healthIdentity: HealthIdentity { .init(phase: phase, message: message) }
}

struct LocalModelLifecycleMetrics: Sendable {
    var verificationPasses = 0
    var hashedBytes: Int64 = 0
    var preparationCount = 0
    var loadedModelCount = 0
    var preparationSeconds: Double = 0
}

struct LocalModelLease: @unchecked Sendable {
    let id: LocalModelID
    let token: UUID
    let directory: URL
    let revision: String
    let models: [String: MLModel]
}

enum LocalModelError: LocalizedError {
    case unavailable, inUse, busy
    case invalidFile(String)
    case download(Int)
    case invalidAssetPath
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Download or verify this model before using it."
        case .inUse: return "Stop the task using this model before removing it."
        case .busy: return "Wait for the current model task to finish."
        case .invalidFile(let path):
            return
                "The model file is missing or does not match the required version: \(path). Copy the required files into the model folder, then choose Refresh."
        case .download(let status): return "The model download returned HTTP \(status). Try again."
        case .invalidAssetPath: return "The model manifest contains an invalid file path."
        }
    }
}

/// One coordinator owns installation, readiness and leases for every local feature.
@MainActor
final class LocalModelManager: ObservableObject {
    static private(set) var shared = LocalModelManager(
        root: LibraryLocation.directory().appendingPathComponent("LocalModels", isDirectory: true),
        storageAvailable: false)

    static func configureShared(dataDirectory: URL, available: Bool, migrateLegacy: Bool) {
        shared = LocalModelManager(
            root: dataDirectory.appendingPathComponent("LocalModels", isDirectory: true),
            storageAvailable: available,
            legacyRoot: migrateLegacy
                ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("GdayMeetings/LocalModels", isDirectory: true) : nil)
    }

    var isBusy: Bool { storageOperations > 0 || !tasks.isEmpty || !leases.isEmpty }
    var isBusyExceptSearch: Bool {
        storageOperations > 0 || !tasks.isEmpty || leases.values.contains { $0 != .granite97M && $0 != .granite311M }
    }
    private var storageOperations = 0
    private var storageSuspended = false

    func suspendForLibraryChange() throws {
        guard !isBusy else { throw LocalModelError.busy }
        storageSuspended = true
    }

    func resumeAfterLibraryChange() { storageSuspended = false }
    private let storageAvailable: Bool
    private let legacyRoot: URL?

    func prepareStorage() async throws {
        guard !storageSuspended else { throw LocalModelError.busy }
        guard storageAvailable else {
            throw MeetingError.message("The data folder is unavailable. Choose a folder in Settings → Data.")
        }
        storageOperations += 1
        defer { storageOperations -= 1 }
        try await worker.importLegacyStorage(from: legacyRoot)
        try await worker.consolidateCommunityAssets(descriptor(.community1))
        try await worker.retireLegacyModels()
    }

    func openableDirectory(for id: LocalModelID) async throws -> URL {
        try await prepareStorage()
        let directory = modelDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @Published private(set) var states: [LocalModelID: LocalModelState] = [:]
    private let root: URL
    private let worker: LocalModelFiles
    private let descriptor: (LocalModelID) -> LocalModelDescriptor
    private var tasks: [LocalModelID: Task<Void, Never>] = [:]
    private var operations: [LocalModelID: UUID] = [:]
    private var leases: [UUID: LocalModelID] = [:]
    private var removing: Set<LocalModelID> = []
    private var communityModels: [String: MLModel] = [:]
    private var communityModelNames: Set<String> = []
    private struct CommunityPreparation {
        let id = UUID()
        let names: Set<String>
        let task: Task<[String: MLModel], Error>
    }
    private var communityPreparation: CommunityPreparation?

    init(
        root: URL,
        storageAvailable: Bool = true,
        legacyRoot: URL? = nil,
        descriptor: @escaping (LocalModelID) -> LocalModelDescriptor = LocalModelRegistry.descriptor,
        preparer: LocalModelFiles.Preparer? = nil,
        remover: LocalModelFiles.Remover? = nil
    ) {
        self.descriptor = descriptor
        self.root = root
        self.storageAvailable = storageAvailable
        self.legacyRoot = legacyRoot
        worker = LocalModelFiles(root: self.root, preparer: preparer, remover: remover)
        for id in LocalModelID.allCases {
            states[id] = .init(totalBytes: descriptor(id).downloadBytes)
        }
    }

    func retireLegacyModels() async throws { try await worker.retireLegacyModels() }

    func lifecycleMetrics() async -> LocalModelLifecycleMetrics { await worker.metrics }

    func state(for id: LocalModelID) -> LocalModelState { states[id] ?? .init() }

    func modelDirectory(for id: LocalModelID) -> URL {
        root.appendingPathComponent(id.rawValue, isDirectory: true)
            .appendingPathComponent(descriptor(id).revision, isDirectory: true)
    }

    /// Inspect receipt and file metadata without hashing files or loading Core ML.
    func health(for id: LocalModelID) async -> ProviderHealth {
        guard storageAvailable, !storageSuspended else { return .notReady("The data folder is unavailable.") }
        return await worker.health(descriptor(id), directory: modelDirectory(for: id))
    }

    func refresh(_ ids: Set<LocalModelID> = Set(LocalModelID.allCases)) async {
        storageOperations += 1
        defer { storageOperations -= 1 }
        do { try await prepareStorage() }
        catch {
            for id in ids where tasks[id] == nil {
                states[id]?.phase = .failed
                states[id]?.message = error.localizedDescription
            }
            return
        }
        for id in ids {
            if !FileManager.default.fileExists(atPath: modelDirectory(for: id).path) {
                states[id]?.phase = .missing
                states[id]?.message = nil
                continue
            }
            if tasks[id] == nil, state(for: id).inUse == 0 { verify(id) }
            await tasks[id]?.value
        }
    }

    /// Explicit provider validation temporarily opens resources, then releases them.
    /// Concurrent requests share the same check, including its runtime preparation.
    func validate(_ id: LocalModelID) async -> ProviderHealth {
        guard storageAvailable, !storageSuspended else { return .notReady("The data folder is unavailable.") }
        let availability = await health(for: id)
        guard availability.isReady else { return availability }
        if await worker.hasPreparationReceipt(descriptor(id), directory: modelDirectory(for: id)) {
            return .ready
        }
        if tasks[id] == nil, state(for: id).inUse == 0 { verify(id) }
        await tasks[id]?.value
        guard state(for: id).phase == .ready else {
            return .notReady(state(for: id).message ?? "Model validation did not complete. Try Refresh.")
        }
        return await health(for: id)
    }

    func download(_ id: LocalModelID) { start(id, download: true) }
    func retry(_ id: LocalModelID) { start(id, download: true) }
    func verify(_ id: LocalModelID) { start(id, download: false) }
    func cancel(_ id: LocalModelID) { tasks[id]?.cancel() }

    private func start(_ id: LocalModelID, download: Bool) {
        guard tasks[id] == nil, state(for: id).inUse == 0 else { return }
        let descriptor = descriptor(id)
        let directory = modelDirectory(for: id)
        let operation = UUID()
        operations[id] = operation
        states[id] = .init(phase: download ? .downloading : .verifying, totalBytes: descriptor.downloadBytes)
        tasks[id] = Task(name: "Prepare local model: \(id.rawValue)") { [weak self] in
            guard let self else { return }
            do {
                try await prepareStorage()
                if download {
                    try await worker.install(descriptor, directory: directory) { [weak self] count in
                        Task { @MainActor in
                            guard let self, self.operations[id] == operation,
                                self.state(for: id).phase == .downloading
                            else { return }
                            self.states[id]?.completedBytes = max(self.state(for: id).completedBytes, count)
                        }
                    }
                }
                try Task.checkCancellation()
                states[id]?.phase = .verifying
                let worker = worker
                try await ProcessingCoordinator.shared.withPermit(for: .modelPreparation, priority: .interactive) {
                    try await worker.verify(descriptor, directory: directory)
                    if !(await worker.hasPreparationReceipt(descriptor, directory: directory)) {
                        _ = try await worker.prepare(descriptor, directory: directory)
                    }
                    try Task.checkCancellation()
                    try await worker.assertUnchanged(descriptor, directory: directory)
                }
                do { try await worker.recordPreparation(descriptor, directory: directory) }
                catch {
                    states[id]?.message =
                        "The model is ready. Verify it again after restarting because its verification receipt could not be saved."
                }
                states[id]?.phase = .ready
                states[id]?.completedBytes = descriptor.downloadBytes
            }
            catch {
                states[id]?.phase = Task.isCancelled ? .cancelled : .failed
                states[id]?.message =
                    Task.isCancelled
                    ? "Model setup was cancelled. Retry to continue with verified files." : error.localizedDescription
            }
            tasks[id] = nil
            operations[id] = nil
        }
    }

    /// The owning query lease keeps the assets resident while its additional execution plan loads.
    func prepareSemanticPassage(for lease: LocalModelLease) async throws -> MLModel {
        guard leases[lease.token] == lease.id else { throw LocalModelError.unavailable }
        let descriptor = descriptor(lease.id)
        let worker = worker
        return try await ProcessingCoordinator.shared.withPermit(for: .modelPreparation, priority: .interactive) {
            try await worker.verify(descriptor, directory: lease.directory)
            let models = try await worker.prepare(
                descriptor, directory: lease.directory, semanticFunction: "passage512")
            try Task.checkCancellation()
            try await worker.assertUnchanged(descriptor, directory: lease.directory)
            guard let model = models["SemanticEncoder"] else { throw LocalModelError.unavailable }
            return model
        }
    }

    func acquireInstalled(
        id: LocalModelID, semanticFunction: String? = nil, priority: ProcessingCoordinator.Priority = .processing
    ) async throws -> LocalModelLease {
        try await acquire(id, semanticFunction: semanticFunction, priority: priority)
    }

    func acquire(
        _ id: LocalModelID, semanticFunction: String? = nil, modelNames: Set<String>? = nil,
        priority: ProcessingCoordinator.Priority = .processing
    ) async throws -> LocalModelLease {
        storageOperations += 1
        defer { storageOperations -= 1 }
        try await prepareStorage()
        guard !removing.contains(id) else { throw LocalModelError.busy }
        // A processing request verifies as needed and retains the instances it opens.
        // It never invokes a separate temporary validation/preparation first.
        if let task = tasks[id] { await task.value }
        try Task.checkCancellation()
        guard tasks[id] == nil, !removing.contains(id) else { throw LocalModelError.busy }
        let token = UUID()
        leases[token] = id
        states[id]?.inUse += 1
        let descriptor = descriptor(id)
        let directory = modelDirectory(for: id)
        do {
            var requested = descriptor
            if let modelNames {
                guard !modelNames.isEmpty, modelNames.isSubset(of: Set(descriptor.modelNames)) else {
                    throw LocalModelError.unavailable
                }
                requested.modelNames = descriptor.modelNames.filter { modelNames.contains($0) }
            }
            let loadingDescriptor = requested
            let worker = worker
            let loaded = try await ProcessingCoordinator.shared.withPermit(for: .modelPreparation, priority: priority) {
                try await worker.verify(descriptor, directory: directory)
                let models: [String: MLModel]
                if id == .community1 {
                    models = try await self.prepareCommunityModels(loadingDescriptor, directory: directory)
                }
                else {
                    models = try await worker.prepare(
                        loadingDescriptor, directory: directory, semanticFunction: semanticFunction)
                }
                try Task.checkCancellation()
                try await worker.assertUnchanged(descriptor, directory: directory)
                if semanticFunction == nil, modelNames == nil {
                    try? await worker.recordPreparation(descriptor, directory: directory)
                }
                return LocalModelLease(
                    id: id, token: token, directory: directory, revision: descriptor.revision, models: models)
            }
            states[id]?.phase = .ready
            states[id]?.message = nil
            return loaded
        }
        catch {
            leases.removeValue(forKey: token)
            states[id]?.inUse -= 1
            discardUnusedCommunityModels()
            if error is CancellationError {
                states[id]?.phase = state(for: id).inUse > 0 ? .ready : .cancelled
                states[id]?.message = nil
            }
            else {
                states[id]?.phase = .failed
                states[id]?.message = error.localizedDescription
            }
            throw error
        }
    }

    func release(_ lease: LocalModelLease) {
        guard let id = leases.removeValue(forKey: lease.token) else { return }
        states[id]?.inUse -= 1
        discardUnusedCommunityModels()
    }

    /// Active users share each graph. Concurrent requests join the same load,
    /// and a full offline request loads only graphs missing from a voice lease.
    private func prepareCommunityModels(_ descriptor: LocalModelDescriptor, directory: URL) async throws
        -> [String: MLModel]
    {
        let requested = Set(descriptor.modelNames)
        while !requested.isSubset(of: communityModelNames) {
            try Task.checkCancellation()
            let pending: CommunityPreparation
            if let current = communityPreparation {
                pending = current
            }
            else {
                var missing = descriptor
                missing.modelNames.removeAll { communityModelNames.contains($0) }
                let loading = missing
                let worker = worker
                pending = CommunityPreparation(
                    names: Set(loading.modelNames),
                    task: Task(name: "Load community voice models") {
                        try await worker.prepare(loading, directory: directory)
                    })
                communityPreparation = pending
            }
            do {
                let loaded = try await pending.task.value
                if communityPreparation?.id == pending.id {
                    communityModels.merge(loaded) { _, new in new }
                    communityModelNames.formUnion(pending.names)
                    communityPreparation = nil
                }
            }
            catch {
                if communityPreparation?.id == pending.id { communityPreparation = nil }
                throw error
            }
        }
        return communityModels.filter { requested.contains($0.key) }
    }

    private func discardUnusedCommunityModels() {
        guard state(for: .community1).inUse == 0 else { return }
        communityModels.removeAll()
        communityModelNames.removeAll()
    }

    func remove(_ id: LocalModelID) async throws {
        storageOperations += 1
        defer { storageOperations -= 1 }
        try await prepareStorage()
        guard state(for: id).inUse == 0 else { throw LocalModelError.inUse }
        guard tasks[id] == nil else { throw LocalModelError.busy }
        guard removing.insert(id).inserted else { throw LocalModelError.busy }
        defer { removing.remove(id) }
        states[id]?.phase = .missing
        do {
            try await worker.remove(directory: modelDirectory(for: id))
            states[id] = .init(totalBytes: descriptor(id).downloadBytes)
        }
        catch {
            states[id]?.phase = .failed
            states[id]?.message = error.localizedDescription
            throw error
        }
    }
}

/// A delegate-owned task delivers byte progress throughout the transfer. The async
/// URLSession convenience download can consume the download delegate callbacks.
final class LocalModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let update: @Sendable (Int64) -> Void
    private let destination: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloaded: Result<(URL, URLResponse), Error>?
    private var cancelled = false

    private init(destination: URL, update: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.update = update
    }

    static func download(
        from url: URL, temporaryDirectory: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let transfer = LocalModelDownload(
            destination: temporaryDirectory.appendingPathComponent(UUID().uuidString), update: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(url, continuation: $0) }
        } onCancel: {
            transfer.cancel()
        }
    }

    private func start(_ url: URL, continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        self.continuation = continuation
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let result: Result<(URL, URLResponse), Error> = Result {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            // URLSession deletes its temporary file after this delegate call returns.
            try FileManager.default.moveItem(at: location, to: destination)
            return (destination, response)
        }
        lock.lock()
        downloaded = result
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        let result: Result<(URL, URLResponse), Error>
        if cancelled {
            result = .failure(CancellationError())
        }
        else if let error {
            result = .failure(error)
        }
        else {
            result = downloaded ?? .failure(URLError(.badServerResponse))
        }
        self.continuation = nil
        self.task = nil
        self.session = nil
        downloaded = nil
        lock.unlock()
        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        update(totalBytesWritten)
    }
}

/// File and Core ML work stays off the main actor. Shared immutable files are hard-linked
/// into each installation; removing one installation cannot remove another's links.
actor LocalModelFiles {
    typealias Remover = @Sendable (URL) async throws -> Void
    private let remover: Remover?
    typealias Preparer = @Sendable (LocalModelDescriptor, URL) async throws -> [String: MLModel]
    let root: URL
    private let preparer: Preparer?
    private(set) var metrics = LocalModelLifecycleMetrics()
    private struct FileIdentity: Codable, Equatable, Sendable {
        let path: String
        let digest: String
        let bytes: Int64
        let inode: UInt64
        let device: UInt64
        let modified: Date
        let created: Date
        var changed: Date
    }
    private struct ValidationReceipt: Codable, Equatable, Sendable {
        let revision: String
        let files: [FileIdentity]
        var runtimeValidated: Bool
    }
    private var verified: [URL: ValidationReceipt] = [:]
    private var rejected: [URL: (ValidationReceipt, String)] = [:]
    private var verifiedDescriptors: [URL: LocalModelDescriptor] = [:]

    private func identity(_ descriptor: LocalModelDescriptor, directory: URL) throws -> ValidationReceipt {
        let files = try descriptor.assets.map { asset -> FileIdentity in
            let url = try safeURL(asset, directory: directory)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            var info = stat()
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                (attrs[.size] as? NSNumber)?.int64Value == asset.bytes,
                lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                let modified = attrs[.modificationDate] as? Date,
                let created = attrs[.creationDate] as? Date
            else { throw LocalModelError.invalidFile(asset.path) }
            let changed = Date(
                timeIntervalSince1970:
                    Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000)
            return .init(
                path: asset.path, digest: asset.digest, bytes: asset.bytes,
                inode: UInt64(info.st_ino), device: UInt64(info.st_dev),
                modified: modified, created: created, changed: changed)
        }
        return .init(revision: descriptor.revision, files: files, runtimeValidated: false)
    }

    private func receipt(directory: URL) -> ValidationReceipt? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent(".gday-validation.json")),
            bytes.count <= 4_194_304
        else { return nil }
        return try? JSONDecoder().decode(ValidationReceipt.self, from: bytes)
    }
    init(root: URL, preparer: Preparer? = nil, remover: Remover? = nil) {
        self.root = root
        self.preparer = preparer
        self.remover = remover
    }

    /// Reuse the retired standalone extractor download without keeping a second installation.
    func consolidateCommunityAssets(_ descriptor: LocalModelDescriptor) throws {
        let fm = FileManager.default
        let retired = root.appendingPathComponent("voiceEmbedding", isDirectory: true)
        let source = retired.appendingPathComponent(descriptor.revision, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return }
        let destination = root.appendingPathComponent(descriptor.id.rawValue, isDirectory: true)
            .appendingPathComponent(descriptor.revision, isDirectory: true)
        for asset in descriptor.assets {
            let old = try safeURL(asset, directory: source)
            let target = try safeURL(asset, directory: destination)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: target.path) else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: target)
        }
        // Acquisition verifies every file before loading; old preparation receipts are not transferred.
        try fm.removeItem(at: source)
        if try fm.contentsOfDirectory(atPath: retired.path).isEmpty { try fm.removeItem(at: retired) }
        try refreshLinkReceipts()
    }

    func retireLegacyModels() throws { try RetiredVoiceSearchMigration.removeModels(root: root) }

    /// Publish a complete copy only when this library has no model folder yet.
    /// Existing library installations and the legacy source are never overwritten.
    func importLegacyStorage(from legacy: URL?) throws {
        guard let legacy, !FileManager.default.fileExists(atPath: root.path),
            FileManager.default.fileExists(atPath: legacy.path)
        else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = root.deletingLastPathComponent().appendingPathComponent(
            ".local-model-import-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staging) }
        try Task.checkCancellation()
        try manager.copyItem(at: legacy, to: staging)
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: root)
    }

    private func safeURL(_ asset: LocalModelAsset, directory: URL) throws -> URL {
        guard !asset.path.hasPrefix("/"), !asset.path.split(separator: "/").contains("..") else {
            throw LocalModelError.invalidAssetPath
        }
        return directory.appendingPathComponent(asset.path)
    }

    func verify(_ descriptor: LocalModelDescriptor, directory: URL) throws {
        let before = try identity(descriptor, directory: directory)
        verifiedDescriptors[directory] = descriptor
        if let (identity, reason) = rejected[directory], identity == before {
            throw LocalModelError.invalidFile(reason)
        }
        rejected.removeValue(forKey: directory)
        if let cached = verified[directory] ?? receipt(directory: directory),
            cached.revision == before.revision, cached.files == before.files
        {
            verified[directory] = cached
            return
        }
        metrics.verificationPasses += 1
        for asset in descriptor.assets {
            try Task.checkCancellation()
            guard try matches(asset, at: safeURL(asset, directory: directory)) else {
                rejected[directory] = (before, asset.path)
                throw LocalModelError.invalidFile(asset.path)
            }
        }
        guard try identity(descriptor, directory: directory) == before else {
            throw LocalModelError.invalidFile("Changed during verification")
        }
        verified[directory] = before
        try JSONEncoder().encode(before).write(
            to: directory.appendingPathComponent(".gday-validation.json"), options: .atomic)
    }

    func assertUnchanged(_ descriptor: LocalModelDescriptor, directory: URL) throws {
        let current = try identity(descriptor, directory: directory)
        guard let cached = verified[directory], cached.revision == current.revision, cached.files == current.files
        else { throw LocalModelError.invalidFile("Changed during preparation") }
    }

    func matches(_ asset: LocalModelAsset, at url: URL) throws -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            attrs[.type] as? FileAttributeType == .typeRegular,
            (attrs[.size] as? NSNumber)?.int64Value == asset.bytes
        else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        if asset.digest.count == 40 { sha1.update(data: Data("blob \(asset.bytes)\0".utf8)) }
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            metrics.hashedBytes += Int64(data.count)
            if asset.digest.count == 40 {
                sha1.update(data: data)
            }
            else {
                sha256.update(data: data)
            }
        }
        let digest = asset.digest.count == 40 ? Array(sha1.finalize()) : Array(sha256.finalize())
        return digest.map { String(format: "%02x", $0) }.joined() == asset.digest
    }

    func install(
        _ descriptor: LocalModelDescriptor, directory: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        let objects = root.appendingPathComponent("objects", isDirectory: true)
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for asset in descriptor.assets {
            try Task.checkCancellation()
            let destination = try safeURL(asset, directory: directory)
            if try matches(asset, at: destination) {
                completed += asset.bytes
                progress(completed)
                continue
            }
            let object = objects.appendingPathComponent(asset.digest)
            if try !matches(asset, at: object) {
                let url = URL(
                    string:
                        "https://huggingface.co/\(descriptor.repository)/resolve/\(descriptor.revision)/\(asset.remotePath)"
                )!
                let base = completed
                let (temporary, response) = try await LocalModelDownload.download(
                    from: url, temporaryDirectory: root.appendingPathComponent("downloads", isDirectory: true)
                ) { progress(base + min(asset.bytes, $0)) }
                defer { try? fm.removeItem(at: temporary) }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw LocalModelError.download((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard try matches(asset, at: temporary) else { throw LocalModelError.invalidFile(asset.path) }
                // Another model may have installed the same object while this request awaited.
                if try !matches(asset, at: object) {
                    if fm.fileExists(atPath: object.path) { try fm.removeItem(at: object) }
                    try fm.copyItem(at: temporary, to: object)
                }
            }
            try Task.checkCancellation()
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.linkItem(at: object, to: destination)
            completed += asset.bytes
            progress(completed)
        }
        try refreshLinkReceipts()
    }

    func prepare(_ descriptor: LocalModelDescriptor, directory: URL, semanticFunction: String? = nil) async throws
        -> [String: MLModel]
    {
        metrics.preparationCount += 1
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics.preparationSeconds += ProcessInfo.processInfo.systemUptime - started }
        if let preparer { return try await preparer(descriptor, directory) }
        var result: [String: MLModel] = [:]
        for name in descriptor.modelNames {
            try Task.checkCancellation()
            let config = MLModelConfiguration()
            config.computeUnits = name == "FBank" ? .cpuOnly : .all
            if name == "SemanticEncoder" { config.functionName = semanticFunction }
            result[name] = try await MLModel.load(
                contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
            metrics.loadedModelCount += 1
        }
        return result
    }

    /// Trusted link changes do not change file contents. Preserve validation while updating only ctime.
    private func refreshLinkReceipts() throws {
        for (directory, descriptor) in verifiedDescriptors {
            guard var cached = verified[directory], var current = try? identity(descriptor, directory: directory),
                cached.revision == current.revision, cached.files.count == current.files.count
            else { continue }
            var comparable = current.files
            for index in comparable.indices { comparable[index].changed = cached.files[index].changed }
            guard comparable == cached.files else { continue }
            current.runtimeValidated = cached.runtimeValidated
            cached = current
            verified[directory] = cached
            try JSONEncoder().encode(cached).write(
                to: directory.appendingPathComponent(".gday-validation.json"), options: .atomic)
        }
    }

    /// Presence is an estimate. Neither hashing nor runtime preparation belongs here.
    func health(_ descriptor: LocalModelDescriptor, directory: URL) -> ProviderHealth {
        do {
            let current = try identity(descriptor, directory: directory)
            if let (identity, _) = rejected[directory], identity == current {
                return .notReady("Required model files failed verification. Replace or download the model.")
            }
            return .ready
        }
        catch { return .notReady("Required model files are missing or incomplete.") }
    }

    func hasPreparationReceipt(_ descriptor: LocalModelDescriptor, directory: URL) -> Bool {
        guard let current = try? identity(descriptor, directory: directory),
            let cached = verified[directory] ?? receipt(directory: directory)
        else { return false }
        return cached.runtimeValidated && cached.revision == current.revision && cached.files == current.files
    }

    func recordPreparation(_ descriptor: LocalModelDescriptor, directory: URL) throws {
        var current = try identity(descriptor, directory: directory)
        guard let cached = verified[directory], cached.revision == current.revision, cached.files == current.files
        else { throw LocalModelError.invalidFile("Changed during preparation") }
        current.runtimeValidated = true
        verified[directory] = current
        try JSONEncoder().encode(current).write(
            to: directory.appendingPathComponent(".gday-validation.json"), options: .atomic)
    }

    func remove(directory: URL) async throws {
        try await remover?(directory)
        verified.removeValue(forKey: directory)
        rejected.removeValue(forKey: directory)
        verifiedDescriptors.removeValue(forKey: directory)
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try refreshLinkReceipts()
        // Object cache supports retries and sharing; reclaim only objects with no installation links.
        let objects = root.appendingPathComponent("objects", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil)) ?? [] {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
                (attrs[.referenceCount] as? NSNumber)?.intValue == 1
            {
                try fm.removeItem(at: url)
            }
        }
    }
}
