import Combine
import Foundation

@MainActor
final class LocalSearchController: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var loadingStartedAt: TimeInterval = 0
    @Published private(set) var loadingDuration: TimeInterval = 1
    @Published private(set) var loadingStage = ""
    @Published var status = "Choose a search model in Service Providers."
    @Published var progress: SearchIndexProgress?
    @Published var error: String?
    private var modelObservation: AnyCancellable?
    private var configured: ServiceProvider?
    private var current: SemanticSearchProvider?
    private var generation = UUID()
    private var indexingGeneration = UUID()
    private var loadingRequest = UUID()
    private var preparation: Task<SemanticSearchProvider, Error>?
    private var preparingProvider: ServiceProvider?
    private var indexing: SemanticSearchProvider?
    private var indexingConfiguration: ServiceProvider?
    private var indexingPreparation: Task<SemanticSearchProvider, Error>?
    private var retirements: [UUID: Task<Void, Never>] = [:]
    private var indexingRelease: Task<Void, Never>?
    var deferredRecordingChanges = false
    fileprivate var scanGeneration = UUID()
    var scanTask: Task<Void, Never>?
    var scanRequested = false
    var forceRebuild = false
    private let directory: URL
    private let indexDirectory: URL
    private let makeEncoder: @MainActor (SemanticModelID, CoreMLSemanticEmbedding.Usage) -> any SemanticEmbedding

    init(
        directory: URL, indexDirectory: URL,
        makeEncoder: @escaping @MainActor (SemanticModelID, CoreMLSemanticEmbedding.Usage) -> any SemanticEmbedding = {
            CoreMLSemanticEmbedding(modelID: $0, manager: .shared, usage: $1)
        }
    ) {
        self.makeEncoder = makeEncoder
        self.directory = directory
        self.indexDirectory = indexDirectory
    }
    func previewLoading() async {
        guard UIPreview.enabled else { return }
        while !Task.isCancelled {
            loadingStartedAt = ProcessInfo.processInfo.systemUptime
            loadingDuration = 8
            isReady = false
            loadingStage = "Loading search model…"
            isLoading = true
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            isReady = true
            isLoading = false
            loadingStage = "Search ready"
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
        }
    }
    func observeModels(_ changed: @escaping @MainActor () -> Void) {
        guard modelObservation == nil else { return }
        modelObservation = LocalModelManager.shared.$states
            .map { states in SemanticModelID.allCases.map { states[$0.localID]?.phase == .ready } }
            .removeDuplicates().dropFirst()
            .sink { ready in if ready.contains(true) { Task { @MainActor in changed() } } }
    }
    func provider(_ provider: ServiceProvider) async throws -> SemanticSearchProvider {
        if configured == provider, let current { return current }
        let request = UUID()
        generation = request
        isReady = false
        let old = current
        current = nil
        configured = provider
        if let old { await old.unload() }
        guard generation == request else { throw CancellationError() }
        let configuration = provider.localSearch ?? .init()
        let directory = directory
        let indexDirectory = indexDirectory
        let index = try await Task.detached(priority: .utility) {
            try SemanticSearchIndex(directory: directory, indexDirectory: indexDirectory)
        }.value
        guard generation == request else { throw CancellationError() }
        let result = SemanticSearchProvider(
            id: provider.id, configuration: configuration, directory: directory,
            index: index, encoder: makeEncoder(configuration.selectedModel, .query))
        current = result
        return result
    }
    /// Typing and submission share one operation rather than cancelling each other's loads.
    func prepare(_ provider: ServiceProvider) async throws -> SemanticSearchProvider {
        if preparingProvider == provider, let preparation { return try await preparation.value }
        if configured == provider, isReady, let current { return current }
        preparation?.cancel()
        let request = UUID()
        loadingRequest = request
        preparingProvider = provider
        let task = Task { try await load(provider, loadRequest: request) }
        preparation = task
        do {
            let result = try await task.value
            if loadingRequest == request {
                preparation = nil
                preparingProvider = nil
            }
            try Task.checkCancellation()
            return result
        }
        catch {
            if loadingRequest == request {
                preparation = nil
                preparingProvider = nil
            }
            throw error
        }
    }

    private func load(_ provider: ServiceProvider, loadRequest: UUID) async throws -> SemanticSearchProvider {

        if configured == provider, isReady, let current { return current }
        defer { if loadingRequest == loadRequest { isLoading = false } }
        isReady = false
        loadingStartedAt = ProcessInfo.processInfo.systemUptime
        loadingDuration = 1
        isLoading = true
        loadingStage = "Loading search index…"
        let indexDirectory = indexDirectory
        let observations = try? await Task.detached(priority: .utility) {
            try RuntimeObservations(indexDirectory: indexDirectory)
        }.value
        let key = "search.prepare.seconds." + (provider.localSearch ?? .init()).selectedModel.space
        let estimate = try? await observations?.value(for: key)
        guard loadingRequest == loadRequest, !Task.isCancelled else { throw CancellationError() }
        loadingDuration = estimate ?? 1
        let startedAt = loadingStartedAt
        let result: SemanticSearchProvider
        do { result = try await self.provider(provider) }
        catch {
            if loadingRequest == loadRequest { isLoading = false }
            throw error
        }
        guard loadingRequest == loadRequest, !Task.isCancelled else { throw CancellationError() }
        let request = generation
        isLoading = true
        loadingStage = "Loading search model…"
        error = nil
        do {
            try await result.prepare()
            guard generation == request, loadingRequest == loadRequest, !Task.isCancelled else {
                throw CancellationError()
            }
            isReady = true
            isLoading = false
            loadingStage = "Search ready"
            if let observations {
                try? await observations.record(ProcessInfo.processInfo.systemUptime - startedAt, for: key)
            }
            return result
        }
        catch {
            if generation == request, loadingRequest == loadRequest, !(error is CancellationError) {
                self.error = error.localizedDescription
            }
            throw error
        }
    }
    func typingBegan(_ provider: ServiceProvider) {
        guard !(configured == provider && isReady), !(preparingProvider == provider && preparation != nil) else {
            return
        }
        Task { _ = try? await prepare(provider) }
    }

    /// Indexing owns separate serial resources; a short query never opens the passage plan.
    func indexingProvider(_ provider: ServiceProvider, retainingResources: Bool = true) async throws
        -> SemanticSearchProvider
    {
        if retainingResources { indexingRelease?.cancel() }
        if indexingConfiguration == provider {
            if let indexing { return indexing }
            if let indexingPreparation { return try await indexingPreparation.value }
        }
        indexingPreparation?.cancel()
        let request = UUID()
        indexingGeneration = request
        let old = indexing
        indexing = nil
        indexingConfiguration = provider
        let root = directory
        let cache = indexDirectory
        let pending = Task {
            await old?.unload()
            let index = try await Task.detached(priority: .utility) {
                try SemanticSearchIndex(directory: root, indexDirectory: cache)
            }.value
            guard request == indexingGeneration, !Task.isCancelled else { throw CancellationError() }
            let result = SemanticSearchProvider(
                id: provider.id, configuration: provider.localSearch ?? .init(),
                directory: root, index: index,
                encoder: makeEncoder((provider.localSearch ?? .init()).selectedModel, .indexing))
            indexing = result
            return result
        }
        indexingPreparation = pending
        defer { if request == indexingGeneration { indexingPreparation = nil } }
        return try await pending.value
    }

    func pauseIndexingForRecording() async {
        indexingGeneration = UUID()
        let pendingIndex = indexingPreparation
        pendingIndex?.cancel()
        indexingPreparation = nil
        let oldScan = scanTask
        scanGeneration = UUID()
        scanTask = nil
        oldScan?.cancel()
        indexingRelease?.cancel()
        let held = indexing
        indexing = nil
        indexingConfiguration = nil
        deferredRecordingChanges = true
        await oldScan?.value
        _ = try? await pendingIndex?.value
        await held?.unload()
    }

    func releaseIndexingResources() async {
        indexingRelease?.cancel()
        let held = indexing
        indexing = nil
        indexingConfiguration = nil
        await held?.unload()
    }

    func indexingFinished() {
        indexingRelease?.cancel()
        indexingRelease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self else { return }
            let held = indexing
            indexing = nil
            indexingConfiguration = nil
            await held?.unload()
        }
    }

    func configurationChanged(_ provider: ServiceProvider?) {
        guard
            (configured != nil && configured != provider)
                || (preparingProvider != nil && preparingProvider != provider)
                || (indexingConfiguration != nil && indexingConfiguration != provider)
        else { return }
        indexingGeneration = UUID()
        let pendingIndex = indexingPreparation
        pendingIndex?.cancel()
        indexingPreparation = nil
        // Clear synchronously before suspension so rapid edits cannot reuse an old generation.
        generation = UUID()
        loadingRequest = UUID()
        let pending = preparation
        pending?.cancel()
        preparation = nil
        preparingProvider = nil
        indexingRelease?.cancel()
        let held = current
        let indexHeld = indexing
        current = nil
        configured = nil
        indexing = nil
        indexingConfiguration = nil
        isReady = false
        isLoading = false
        let token = UUID()
        retirements[token] = Task { [weak self] in
            _ = try? await pending?.value
            _ = try? await pendingIndex?.value
            await held?.unload()
            await indexHeld?.unload()
            self?.retirements.removeValue(forKey: token)
        }
    }

    func removeMeeting(_ id: UUID) async {
        do {
            let directory = directory
            let indexDirectory = indexDirectory
            let index: SemanticSearchIndex
            if let current {
                index = current.index
            }
            else {
                index = try await Task.detached(priority: .utility) {
                    try SemanticSearchIndex(directory: directory, indexDirectory: indexDirectory)
                }.value
            }
            try await index.remove(id)
        }
        catch { self.error = error.localizedDescription }
    }
    func shutdown() async {
        // Detach this generation before awaiting retirement. New requests may safely
        // acquire their own resources while old cancellation finishes.
        generation = UUID()
        indexingGeneration = UUID()
        loadingRequest = UUID()
        scanGeneration = UUID()
        let pending = preparation
        let pendingIndex = indexingPreparation
        let oldScan = scanTask
        let held = current
        let indexHeld = indexing
        let retiring = Array(retirements.values)
        preparation = nil
        preparingProvider = nil
        indexingPreparation = nil
        scanTask = nil
        current = nil
        configured = nil
        indexing = nil
        indexingConfiguration = nil
        indexingRelease?.cancel()
        indexingRelease = nil
        isReady = false
        isLoading = false
        pending?.cancel()
        pendingIndex?.cancel()
        oldScan?.cancel()
        _ = try? await pending?.value
        _ = try? await pendingIndex?.value
        await oldScan?.value
        for retirement in retiring { await retirement.value }
        await indexHeld?.unload()
        await held?.unload()
    }
}

extension MeetingStore {
    var selectedSearchProvider: ServiceProvider? {
        guard settings.defaultSearchMode == .semantic else { return nil }
        return settings.serviceProviders.first {
            $0.id == settings.searchProviderID && $0.kind == .localSearch && $0.supports(.search)
        }
    }
    func searchConfigurationChanged() {
        guard libraryWritable, !isPreparingToQuit, !isChangingLibrary else { return }
        localSearch.observeModels { [weak self] in self?.searchConfigurationChanged() }
        settings.selectSoleSearchProvider()
        guard let provider = selectedSearchProvider else {
            localSearch.configurationChanged(nil)
            return
        }
        localSearch.configurationChanged(provider)
        scheduleSearchIndexing()
    }
    func scheduleSearchIndexing(rebuild: Bool = false) {
        let controller = localSearch
        controller.scanRequested = true
        controller.forceRebuild = controller.forceRebuild || rebuild
        guard recordingID == nil, !isStartingRecording, !isFinalizingRecording else {
            controller.deferredRecordingChanges = true
            if rebuild { controller.status = "Rebuild queued until recording finishes." }
            return
        }
        guard controller.scanTask == nil, libraryWritable, !isPreparingToQuit, !isChangingLibrary,
            let libraryIndex
        else { return }
        let scanGeneration = UUID()
        controller.scanGeneration = scanGeneration
        controller.scanTask = Task { [weak self] in
            defer { if controller.scanGeneration == scanGeneration { controller.scanTask = nil } }
            // Coalesce file notifications and finalized live-transcript checkpoints.
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            while controller.scanRequested, !Task.isCancelled {
                controller.scanRequested = false
                guard let self, !self.isPreparingToQuit, !self.isChangingLibrary,
                    let selected = self.selectedSearchProvider
                else { return }
                // During capture remember the change, without building a task per checkpoint.
                guard self.recordingID == nil, !self.isStartingRecording, !self.isFinalizingRecording else {
                    controller.deferredRecordingChanges = true
                    return
                }
                let rebuild = controller.forceRebuild
                controller.forceRebuild = false
                let model = (selected.localSearch ?? .init()).selectedModel
                let health = await LocalModelManager.shared.health(for: model.localID)
                guard !Task.isCancelled else { return }
                guard health.isReady else {
                    controller.status = "Waiting for \(model.title). Download or verify it in Service Providers."
                    return
                }
                do {
                    let provider = try await controller.indexingProvider(selected, retainingResources: false)
                    if rebuild { try await provider.resetIndex() }
                    var cursor: MeetingListEntry?
                    var pending = 0
                    scan: while !Task.isCancelled {
                        let after = cursor
                        let entries = try await Task.detached(priority: .utility) {
                            try libraryIndex.page(after: after, limit: 20)
                        }.value
                        if entries.isEmpty { break }
                        for entry in entries {
                            try Task.checkCancellation()
                            guard self.recordingID == nil, !self.isStartingRecording, !self.isFinalizingRecording else {
                                controller.deferredRecordingChanges = true
                                return
                            }
                            guard self.selectedSearchProvider == selected else {
                                controller.scanRequested = true
                                break scan
                            }
                            let directory = self.dataDirectory
                            let fingerprint = try await Task.detached(priority: .utility) {
                                try SemanticSource.fingerprint(
                                    folder: MeetingFolderLocation.resolve(id: entry.id, directory: directory))
                            }.value
                            if try await !provider.index.isCurrent(
                                entry.id, space: model.space, fingerprint: fingerprint)
                            {
                                pending += 1
                                _ = await self.queueSearchIndex(
                                    id: entry.id, revision: model.space + ":" + fingerprint, force: rebuild)
                            }
                        }
                        cursor = entries.last
                    }
                    controller.status =
                        pending > 0
                        ? "\(pending) meetings need indexing. See Tasks for progress." : "Search index is up to date."
                    controller.error = nil
                }
                catch {
                    if !Task.isCancelled { controller.error = error.localizedDescription }
                }
            }
        }
    }
    func performSearchIndex(id: UUID, providerID: UUID?) async throws {
        guard let selected = selectedSearchProvider, selected.id == providerID else { throw CancellationError() }
        guard recordingID == nil, !isStartingRecording, !isFinalizingRecording else { throw CancellationError() }
        let provider = try await localSearch.indexingProvider(selected)
        defer {
            localSearch.progress = nil
            localSearch.indexingFinished()
        }
        try await provider.updateIndex(meetingID: id, rebuild: false) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.selectedSearchProvider == selected else { return }
                self.localSearch.progress = progress
                self.setJobProgress(
                    .searchIndex, .meeting(id), "Indexing passages: \(progress.completed) of \(progress.total)")
            }
        }
    }
}

extension AppSettings {
    mutating func selectSoleSearchProvider() {
        let eligible = serviceProviders.filter { $0.supports(.search) }
        if eligible.count == 1 { searchProviderID = eligible[0].id }
    }
}
