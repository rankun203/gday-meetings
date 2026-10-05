import Darwin
import Foundation

struct LocalSearchEmbeddingResponse: Decodable, Sendable {
    let model: String
    let revision: String
    let preprocessing: String
    let dimension: Int
    let normalization: String
    let vectors: [[Double]]
}

/// One optional subprocess keeps model loading out of startup and reuses it between requests.
/// The worker has no database access; the app persists provider artifacts and derived projections.
final class LocalSearchWorkerClient: @unchecked Sendable {
    private struct Request: Encodable {
        let id: UUID
        let operation: String
        var texts: [String]? = nil
        var path: String? = nil
        var start: Double? = nil
        var duration: Double? = nil
    }
    private struct Response: Decodable {
        let id: UUID?
        let final: Bool
        let result: LocalSearchEmbeddingResponse?
        let error: String?
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var expired = false
        func cancel() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
        func timeOut() {
            lock.lock()
            if !stopped { expired = true }
            stopped = true
            lock.unlock()
        }
        var failure: Error {
            lock.lock()
            defer { lock.unlock() }
            return expired
                ? ServiceError(
                    "The local search worker took too long. Try again, or check its configuration in Service Providers."
                )
                : CancellationError()
        }
    }

    private let executable: URL
    private let modelCache: URL
    private let timeoutSeconds: TimeInterval
    private let queue = DispatchQueue(label: "com.gdaymeetings.search-worker", qos: .utility)
    private let stateLock = NSLock()
    private var activeID: UUID?
    private var activeCancellation: Cancellation?
    private var isShutDown = false
    private var process: Process?
    private var retiringProcesses: [Process] = []
    private var input: FileHandle?
    private var output: FileHandle?
    private let responseLimit = 4 * 1024 * 1024

    init(executable: URL, modelCache: URL, timeoutSeconds: TimeInterval = 180) {
        self.executable = executable
        self.modelCache = modelCache
        self.timeoutSeconds = timeoutSeconds
    }
    deinit {
        for owned in retiringProcesses + [process].compactMap({ $0 }) where owned.isRunning {
            owned.terminate()
        }
    }

    /// Stop owned processes explicitly; app termination does not guarantee deinit.
    func shutdown() async {
        let owned = beginShutdown()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while owned.contains(where: \.isRunning), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { break }
        }
        for process in owned where process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func beginShutdown() -> [Process] {
        stateLock.lock()
        defer { stateLock.unlock() }
        isShutDown = true
        activeCancellation?.cancel()
        retiringProcesses.removeAll { !$0.isRunning }
        if let process, process.isRunning { retiringProcesses.append(process) }
        process = nil
        for owned in retiringProcesses where owned.isRunning { owned.terminate() }
        return retiringProcesses
    }

    func embed(texts: [String]) async throws -> LocalSearchEmbeddingResponse {
        guard !texts.isEmpty, texts.count <= 64, texts.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else {
            throw ServiceError("Enter a search description of up to 4,096 characters.")
        }
        return try await request(.init(id: UUID(), operation: "embed_text", texts: texts))
    }
    func embed(audio: URL, start: Double, duration: Double) async throws -> LocalSearchEmbeddingResponse {
        guard audio.isFileURL, start.isFinite, duration.isFinite, start >= 0, duration > 0, duration <= 30 else {
            throw ServiceError("Choose an audio range of up to 30 seconds.")
        }
        return try await request(
            .init(id: UUID(), operation: "embed_audio", path: audio.path, start: start, duration: duration))
    }

    private func request(_ request: Request) async throws -> LocalSearchEmbeddingResponse {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    stateLock.lock()
                    if isShutDown {
                        stateLock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    activeID = request.id
                    activeCancellation = cancellation
                    stateLock.unlock()
                    let timeout = DispatchWorkItem { [weak self] in
                        cancellation.timeOut()
                        self?.stop(request.id)
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
                    defer {
                        timeout.cancel()
                        stateLock.lock()
                        activeID = nil
                        activeCancellation = nil
                        stateLock.unlock()
                    }
                    do {
                        try startIfNeeded()
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        var data = try JSONEncoder().encode(request)
                        data.append(10)
                        try input?.write(contentsOf: data)
                        var response = Data()
                        while !response.contains(10) {
                            guard !cancellation.isCancelled else { throw CancellationError() }
                            guard let output else {
                                throw ServiceError("The local search worker stopped before returning a result.")
                            }
                            // FileHandle's count-based read can wait for the entire
                            // buffer on a persistent pipe. POSIX read returns the
                            // currently available chunk, allowing newline framing.
                            var buffer = [UInt8](repeating: 0, count: 8192)
                            let count = buffer.withUnsafeMutableBytes {
                                Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count)
                            }
                            if count < 0, errno == EINTR { continue }
                            guard count > 0 else {
                                throw ServiceError("The local search worker stopped before returning a result.")
                            }
                            response.append(contentsOf: buffer.prefix(count))
                            guard response.count <= responseLimit else { throw SearchProviderError.invalidResponse }
                        }
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        let decoded = try JSONDecoder().decode(Response.self, from: response)
                        guard decoded.id == request.id, decoded.final else { throw SearchProviderError.invalidResponse }
                        if let error = decoded.error {
                            throw ServiceError("The local search worker couldn’t finish. \(error)")
                        }
                        guard let result = decoded.result, result.model == LocalSearchConfiguration.modelID,
                            result.revision == LocalSearchConfiguration.modelRevision,
                            result.preprocessing == "clsp-16khz-mono-v1", result.dimension == 512,
                            result.normalization == "unitL2", result.vectors.count == (request.texts?.count ?? 1),
                            result.vectors.allSatisfy({ vector in
                                vector.count == result.dimension && vector.allSatisfy(\.isFinite)
                                    && abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.002
                            })
                        else { throw SearchProviderError.invalidResponse }
                        continuation.resume(returning: result)
                    }
                    catch {
                        stop(request.id)
                        try? input?.close()
                        try? output?.close()
                        input = nil
                        output = nil
                        continuation.resume(throwing: cancellation.isCancelled ? cancellation.failure : error)
                    }
                }
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            self?.stop(request.id)
        }
    }

    private func stop(_ id: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if activeID == id {
            retiringProcesses.removeAll { !$0.isRunning }
            if let process, process.isRunning {
                retiringProcesses.append(process)
                process.terminate()
                // Cancellation must also stop a worker that ignores SIGTERM.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
            process = nil
        }
    }
    private func startIfNeeded() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutDown else { throw CancellationError() }
        if let process, process.isRunning { return }
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ServiceError("Choose the installed local search worker executable in Service Providers.")
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["serve", "--device", "cpu", "--threads", "4"]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = modelCache.path
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
    }
}
