import Combine
import CoreML
import CryptoKit
import Foundation

enum LocalModelPhase: String, Sendable {
    case missing, unverified, downloading, verifying, preparing, ready, cancelled, failed
}

struct LocalModelState: Sendable {
    var phase: LocalModelPhase = .missing
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var message: String?
    var inUse = 0
    var progress: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }
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
                "The model file is missing or does not match the required version: \(path). Copy the required files into the model folder, then choose Verify."
        case .download(let status): return "The model download returned HTTP \(status). Try again."
        case .invalidAssetPath: return "The model manifest contains an invalid file path."
        }
    }
}

/// One coordinator owns installation, readiness and leases for every local feature.
@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()
    @Published private(set) var states: [LocalModelID: LocalModelState] = [:]
    private let root: URL
    private let worker: LocalModelFiles
    private let descriptor: (LocalModelID) -> LocalModelDescriptor
    private var tasks: [LocalModelID: Task<Void, Never>] = [:]
    private var operations: [LocalModelID: UUID] = [:]
    private var leases: [UUID: LocalModelID] = [:]

    init(
        root: URL? = nil,
        descriptor: @escaping (LocalModelID) -> LocalModelDescriptor = LocalModelRegistry.descriptor,
        preparer: LocalModelFiles.Preparer? = nil
    ) {
        self.descriptor = descriptor
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GdayMeetings/LocalModels", isDirectory: true)
        worker = LocalModelFiles(root: self.root, preparer: preparer)
        for id in LocalModelID.allCases {
            states[id] = .init(totalBytes: descriptor(id).downloadBytes)
        }
    }

    func state(for id: LocalModelID) -> LocalModelState { states[id] ?? .init() }

    func modelDirectory(for id: LocalModelID) -> URL {
        root.appendingPathComponent(id.rawValue, isDirectory: true)
            .appendingPathComponent(descriptor(id).revision, isDirectory: true)
    }

    func refresh() async {
        for id in LocalModelID.allCases where tasks[id] == nil && state(for: id).inUse == 0 {
            // Ready means this process verified and prepared the exact pinned assets.
            // An externally copied folder is never a readiness receipt.
            let directory = modelDirectory(for: id)
            if state(for: id).phase == .ready {
                do {
                    try await worker.verify(descriptor(id), directory: directory)
                    continue
                }
                catch { states[id]?.message = error.localizedDescription }
            }
            let exists = FileManager.default.fileExists(atPath: directory.path)
            states[id]?.phase = exists ? .unverified : .missing
            if exists, await worker.hasPreparationReceipt(descriptor(id), directory: directory) {
                // A receipt requests verification; it never bypasses hashes or preparation.
                verify(id)
            }
        }
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
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
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
                try await worker.verify(descriptor, directory: directory)
                try Task.checkCancellation()
                states[id]?.phase = .preparing
                _ = try await worker.prepare(descriptor, directory: directory)
                try Task.checkCancellation()
                do { try await worker.recordPreparation(descriptor, directory: directory) }
                catch {
                    states[id]?.message =
                        "The model is ready. Verify it again after restarting because its verification receipt could not be saved."
                }
                if id == .community1, tasks[.voiceEmbedding] == nil, state(for: .voiceEmbedding).inUse == 0 {
                    let subset = self.descriptor(.voiceEmbedding)
                    let subsetDirectory = modelDirectory(for: .voiceEmbedding)
                    // The embedding graph and preprocessing were just prepared as part of Community-1.
                    // Materialize the identical verified files without another network request.
                    do {
                        try await worker.materializeSubset(subset, source: directory, destination: subsetDirectory)
                        try? await worker.recordPreparation(subset, directory: subsetDirectory)
                        states[.voiceEmbedding] = .init(
                            phase: .ready, completedBytes: subset.downloadBytes, totalBytes: subset.downloadBytes)
                    }
                    catch {
                        states[.voiceEmbedding]?.phase = .failed
                        states[.voiceEmbedding]?.message = error.localizedDescription
                    }
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

    func acquireInstalled(id: LocalModelID) async throws -> LocalModelLease { try await acquire(id) }

    func acquire(_ id: LocalModelID) async throws -> LocalModelLease {
        if state(for: id).phase != .ready {
            if tasks[id] == nil,
                await worker.hasPreparationReceipt(descriptor(id), directory: modelDirectory(for: id))
            {
                verify(id)
            }
            else if id == .voiceEmbedding, tasks[id] == nil,
                await worker.hasPreparationReceipt(descriptor(.community1), directory: modelDirectory(for: .community1))
            {
                if tasks[.community1] == nil { verify(.community1) }
                await tasks[.community1]?.value
            }
            if [.verifying, .preparing].contains(state(for: id).phase) { await tasks[id]?.value }
            try Task.checkCancellation()
        }
        guard state(for: id).phase == .ready, tasks[id] == nil else { throw LocalModelError.unavailable }
        let token = UUID()
        leases[token] = id
        states[id]?.inUse += 1
        let descriptor = descriptor(id)
        let directory = modelDirectory(for: id)
        do {
            // Recheck external modifications before opening any model.
            try await worker.verify(descriptor, directory: directory)
            // Synchronous Core ML prediction must be serialized per instance.
            // Each lease has its own models so independent workers cannot race them.
            let models = try await worker.prepare(descriptor, directory: directory)
            try Task.checkCancellation()
            return .init(id: id, token: token, directory: directory, revision: descriptor.revision, models: models)
        }
        catch {
            leases.removeValue(forKey: token)
            states[id]?.inUse -= 1
            states[id]?.phase = .failed
            states[id]?.message = error.localizedDescription
            throw error
        }
    }

    func release(_ lease: LocalModelLease) {
        guard let id = leases.removeValue(forKey: lease.token) else { return }
        states[id]?.inUse -= 1
    }

    func remove(_ id: LocalModelID) async throws {
        guard state(for: id).inUse == 0 else { throw LocalModelError.inUse }
        guard tasks[id] == nil else { throw LocalModelError.busy }
        // Mark unavailable before yielding so a concurrent acquire cannot race removal.
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
    typealias Preparer = @Sendable (LocalModelDescriptor, URL) async throws -> [String: MLModel]
    let root: URL
    private let preparer: Preparer?
    init(root: URL, preparer: Preparer? = nil) {
        self.root = root
        self.preparer = preparer
    }

    private func safeURL(_ asset: LocalModelAsset, directory: URL) throws -> URL {
        guard !asset.path.hasPrefix("/"), !asset.path.split(separator: "/").contains("..") else {
            throw LocalModelError.invalidAssetPath
        }
        return directory.appendingPathComponent(asset.path)
    }

    func verify(_ descriptor: LocalModelDescriptor, directory: URL) throws {
        for asset in descriptor.assets {
            try Task.checkCancellation()
            guard try matches(asset, at: safeURL(asset, directory: directory)) else {
                throw LocalModelError.invalidFile(asset.path)
            }
        }
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
    }

    func prepare(_ descriptor: LocalModelDescriptor, directory: URL) async throws -> [String: MLModel] {
        if let preparer { return try await preparer(descriptor, directory) }
        var result: [String: MLModel] = [:]
        for name in descriptor.modelNames {
            try Task.checkCancellation()
            let config = MLModelConfiguration()
            config.computeUnits = name == "FBank" ? .cpuOnly : .all
            result[name] = try await MLModel.load(
                contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        return result
    }

    func materializeSubset(_ descriptor: LocalModelDescriptor, source: URL, destination: URL) throws {
        try verify(descriptor, directory: source)
        let fm = FileManager.default
        let objects = root.appendingPathComponent("objects", isDirectory: true)
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        for asset in descriptor.assets {
            try Task.checkCancellation()
            let object = objects.appendingPathComponent(asset.digest)
            if try !matches(asset, at: object) {
                if fm.fileExists(atPath: object.path) { try fm.removeItem(at: object) }
                try fm.copyItem(at: safeURL(asset, directory: source), to: object)
            }
            let target = try safeURL(asset, directory: destination)
            if try matches(asset, at: target) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.linkItem(at: object, to: target)
        }
    }

    func hasPreparationReceipt(_ descriptor: LocalModelDescriptor, directory: URL) -> Bool {
        (try? String(contentsOf: directory.appendingPathComponent(".gday-prepared"), encoding: .utf8))
            == descriptor.revision
    }

    func recordPreparation(_ descriptor: LocalModelDescriptor, directory: URL) throws {
        try Data(descriptor.revision.utf8).write(
            to: directory.appendingPathComponent(".gday-prepared"), options: .atomic)
    }

    func remove(directory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
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
