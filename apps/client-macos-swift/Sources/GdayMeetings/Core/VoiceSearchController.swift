import Combine
import Foundation

/// Optional search preparation is explicit and stays outside app startup.
@MainActor
final class VoiceSearchController: ObservableObject {
    @Published private(set) var isBuilding = false
    @Published private(set) var buildingMeetingID: UUID?
    @Published private(set) var progress: VoiceSearchBuildProgress?
    @Published private(set) var statusMessage: String?
    @Published private(set) var error: String?
    private let directory: URL
    private let indexDirectory: URL
    private var preparedConfiguration: LocalSearchConfiguration?
    private var preparation: Task<LocalVoiceSearchProvider, Error>?
    private var buildTask: Task<Void, Never>?
    private var preparationGeneration = UUID()
    private var isShuttingDown = false
    private final class ProviderReference {
        weak var value: LocalVoiceSearchProvider?
        init(_ value: LocalVoiceSearchProvider) { self.value = value }
    }
    private var ownedProviders: [ProviderReference] = []

    init(directory: URL, indexDirectory: URL) {
        self.directory = directory
        self.indexDirectory = indexDirectory
    }

    func provider(configuration: LocalSearchConfiguration) async throws -> LocalVoiceSearchProvider {
        guard !isShuttingDown else { throw CancellationError() }
        if preparedConfiguration != configuration || preparation == nil {
            let directory = directory
            let indexDirectory = indexDirectory
            preparedConfiguration = configuration
            preparationGeneration = UUID()
            preparation = Task.detached(priority: .utility) {
                try configuration.validatePreparedFiles()
                guard let executable = configuration.executableURL, let cache = configuration.modelCacheURL else {
                    throw ServiceError("Choose a local search worker and prepared model folder.")
                }
                return try LocalVoiceSearchProvider(
                    directory: directory, indexDirectory: indexDirectory,
                    worker: LocalSearchWorkerClient(executable: executable, modelCache: cache))
            }
        }
        guard let preparation else { throw SearchProviderError.incompleteResponse }
        let generation = preparationGeneration
        do {
            let provider = try await preparation.value
            guard generation == preparationGeneration, !isShuttingDown else {
                await provider.shutdown()
                throw CancellationError()
            }
            ownedProviders.removeAll { $0.value == nil }
            if !ownedProviders.contains(where: { $0.value === provider }) {
                ownedProviders.append(ProviderReference(provider))
            }
            return provider
        }
        catch {
            if generation == preparationGeneration { self.preparation = nil }
            throw error
        }
    }

    func buildLibrary(
        configuration: LocalSearchConfiguration, libraryIndex: LibraryIndex?,
        excludingTagIDs: Set<UUID> = [], excludingMeetingIDs: Set<UUID> = []
    ) {
        guard !isBuilding, !isShuttingDown else { return }
        guard let libraryIndex else {
            error = "Wait for the library index to finish loading, then try again."
            return
        }
        isBuilding = true
        progress = nil
        statusMessage = "Preparing voice index…"
        error = nil
        buildTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isBuilding = false
                buildingMeetingID = nil
                buildTask = nil
            }
            do {
                let provider = try await provider(configuration: configuration)
                var cursor: MeetingListEntry?
                var meetings = 0
                var clips = 0
                var failures = 0
                while true {
                    try Task.checkCancellation()
                    let after = cursor
                    let page = try await Task.detached(priority: .utility) {
                        try libraryIndex.page(after: after, limit: 20, excludingTagIDs: excludingTagIDs)
                    }.value
                    if page.isEmpty { break }
                    for entry in page where !entry.audioFiles.isEmpty && !excludingMeetingIDs.contains(entry.id) {
                        try Task.checkCancellation()
                        buildingMeetingID = entry.id
                        statusMessage = "Indexing \(entry.title)…"
                        do {
                            clips += try await provider.build(meetingID: entry.id) { [weak self] progress in
                                Task { @MainActor in
                                    guard let self, self.isBuilding, self.buildingMeetingID == progress.meetingID else {
                                        return
                                    }
                                    self.progress = progress
                                }
                            }
                            meetings += 1
                        }
                        catch {
                            if Task.isCancelled { throw CancellationError() }
                            failures += 1
                            self.error = error.localizedDescription
                        }
                    }
                    cursor = page.last
                }
                statusMessage = "Indexed \(clips.formatted()) audio clips in \(meetings.formatted()) meetings."
                if failures > 0 {
                    statusMessage =
                        (statusMessage ?? "")
                        + " \(failures.formatted()) meetings couldn’t be indexed. Try again to resume."
                }
            }
            catch {
                if Task.isCancelled {
                    statusMessage = "Indexing stopped. Completed audio clips were kept."
                }
                else {
                    self.error = error.localizedDescription
                    statusMessage = nil
                }
            }
        }
    }

    func cancel() {
        buildTask?.cancel()
        if isBuilding { statusMessage = "Stopping indexing…" }
    }

    func shutdown() async {
        isShuttingDown = true
        defer { isShuttingDown = false }
        cancel()
        preparationGeneration = UUID()
        preparation?.cancel()
        preparation = nil
        preparedConfiguration = nil
        let providers = ownedProviders.compactMap(\.value)
        ownedProviders = []
        await withTaskGroup(of: Void.self) { group in
            for provider in providers { group.addTask { await provider.shutdown() } }
        }
        // File reads are cooperatively cancellable. Do not make quitting wait
        // indefinitely for a stalled external filesystem after workers stop.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while isBuilding, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { break }
        }
    }

    func invalidateDeletedMeeting(_ meetingID: UUID) {
        let directory = directory
        let indexDirectory = indexDirectory
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try LocalVoiceSearchIndex(directory: directory, indexDirectory: indexDirectory)
                        .invalidate(meetingID: meetingID)
                }.value
            }
            catch {
                self?.error =
                    "The meeting was deleted, but its cached voice embeddings couldn’t be removed. Rebuild the index from saved embeddings."
            }
        }
    }

    func rebuildSavedEmbeddings() {
        guard !isBuilding, !isShuttingDown else { return }
        isBuilding = true
        progress = nil
        error = nil
        statusMessage = "Rebuilding the index from saved embeddings…"
        let directory = directory
        let indexDirectory = indexDirectory
        buildTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isBuilding = false
                buildTask = nil
            }
            let task = Task.detached(priority: .utility) {
                try LocalVoiceSearchIndex(directory: directory, indexDirectory: indexDirectory).rebuild()
            }
            do {
                let report = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                try Task.checkCancellation()
                statusMessage = "Restored \(report.indexedClips.formatted()) audio clips to the index."
                if report.rejectedArtifacts > 0 {
                    error =
                        "\(report.rejectedArtifacts.formatted()) saved embeddings no longer match their audio or model. Build the voice index again to replace them."
                }
            }
            catch {
                if Task.isCancelled {
                    statusMessage = "Index rebuilding stopped."
                }
                else {
                    self.error = error.localizedDescription
                    statusMessage = nil
                }
            }
        }
    }
}
