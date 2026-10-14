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
    var scanTask: Task<Void, Never>? {
        didSet { scanActivityChanged(scanTask != nil) }
    }
    private let scanActivityChanged: @MainActor (Bool) -> Void
    let fingerprintCache = SemanticFingerprintCache()
    var scanRequested = false
    var scanRequestedAt = ContinuousClock.now
    var observedSearchConfiguration: String?
    @Published var rebuildRequest: SearchIndexRebuild?
    let rebuildURL: URL
    private let directory: URL
    private let indexDirectory: URL
    private let makeEncoder: @MainActor (SemanticModelID, CoreMLSemanticEmbedding.Usage) -> any SemanticEmbedding
    let modelReady: @MainActor (SemanticModelID) async -> Bool

    init(
        directory: URL, indexDirectory: URL,
        scanActivityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        makeEncoder: @escaping @MainActor (SemanticModelID, CoreMLSemanticEmbedding.Usage) -> any SemanticEmbedding = {
            CoreMLSemanticEmbedding(modelID: $0, manager: .shared, usage: $1)
        },
        modelReady: @escaping @MainActor (SemanticModelID) async -> Bool = {
            await LocalModelManager.shared.health(for: $0.localID).isReady
        }
    ) {
        self.scanActivityChanged = scanActivityChanged
        self.makeEncoder = makeEncoder
        self.modelReady = modelReady
        self.directory = directory
        self.indexDirectory = indexDirectory
        rebuildURL = directory.appendingPathComponent("search-index-rebuild.json")
        if FileManager.default.fileExists(atPath: rebuildURL.path) {
            do {
                rebuildRequest = try JSONDecoder().decode(SearchIndexRebuild.self, from: Data(contentsOf: rebuildURL))
            }
            catch { self.error = error.localizedDescription }
        }
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
        settings.selectedSearchProvider
    }
    func searchConfigurationChanged() {
        guard libraryWritable, !isPreparingToQuit, !isChangingLibrary else { return }
        localSearch.observeModels { [weak self] in self?.searchConfigurationChanged() }
        settings.selectSoleSearchProvider()
        guard let provider = selectedSearchProvider else {
            localSearch.configurationChanged(nil)
            localSearch.observedSearchConfiguration = nil
            return
        }
        localSearch.configurationChanged(provider)
        let model = (provider.localSearch ?? .init()).selectedModel
        let ready = LocalModelManager.shared.states[model.localID]?.phase == .ready
        let configuration = "\(provider.id):\(model.space):\(ready)"
        guard localSearch.observedSearchConfiguration != configuration else { return }
        localSearch.observedSearchConfiguration = configuration
        scheduleSearchIndexing()
    }
    func scheduleSearchIndexing(rebuild: Bool = false) {
        let controller = localSearch
        controller.scanRequested = true
        controller.scanRequestedAt = .now
        if rebuild, controller.rebuildRequest?.isActive != true {
            do {
                try controller.saveRebuild(.init())
                controller.status = "Preparing rebuild…"
            }
            catch {
                controller.error = error.localizedDescription
                return
            }
        }
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
            while controller.scanRequested, !Task.isCancelled {
                // Wait for a quiet interval on every pass, including notifications
                // received during the previous scan. Active editors are gated below.
                do {
                    while controller.scanRequestedAt.duration(to: .now) < .seconds(2) {
                        try await Task.sleep(until: controller.scanRequestedAt.advanced(by: .seconds(2)))
                    }
                }
                catch { return }
                controller.scanRequested = false
                let sourceRequest = controller.scanRequestedAt
                guard let self, !self.isPreparingToQuit, !self.isChangingLibrary,
                    let selected = self.selectedSearchProvider
                else { return }
                // During capture remember the change, without building a task per checkpoint.
                guard self.recordingID == nil, !self.isStartingRecording, !self.isFinalizingRecording else {
                    controller.deferredRecordingChanges = true
                    return
                }
                let model = (selected.localSearch ?? .init()).selectedModel
                let ready = await controller.modelReady(model)
                guard !Task.isCancelled else { return }
                guard ready else {
                    controller.status = "Waiting for \(model.title). Download or verify it in Service Providers."
                    return
                }
                do {
                    let provider = try await controller.indexingProvider(selected, retainingResources: false)
                    try await self.refreshSearchIndexRebuild()
                    if var request = controller.rebuildRequest, request.isActive {
                        if let space = request.modelSpace, space != model.space {
                            await self.cancelSearchIndexRebuild()
                        }
                        else {
                            request.modelSpace = model.space
                            if request.meetings == nil {
                                request.meetings = try await Task.detached(priority: .utility) {
                                    var ids: [UUID] = []
                                    var cursor: MeetingListEntry?
                                    while true {
                                        let page = try libraryIndex.page(after: cursor, limit: 200)
                                        guard !page.isEmpty else { return ids }
                                        ids.append(contentsOf: page.map(\.id))
                                        cursor = page.last
                                    }
                                }.value
                            }
                            if controller.rebuildRequest?.id == request.id,
                                controller.rebuildRequest?.isActive == true
                            {
                                request.state = .running
                                try controller.saveRebuild(request)
                            }
                        }
                    }
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
                            if controller.scanRequestedAt != sourceRequest {
                                controller.scanRequested = true
                                break scan
                            }
                            guard !self.notesStorage.isEditing(entry.id) else { continue }
                            let directory = self.dataDirectory
                            let folder = try await Task.detached(priority: .utility) {
                                try MeetingFolderLocation.resolve(id: entry.id, directory: directory)
                            }.value
                            let fingerprint = try await controller.fingerprintCache.fingerprint(folder: folder)
                            guard !self.notesStorage.isEditing(entry.id) else { continue }
                            let batch = controller.rebuildRequest.flatMap {
                                $0.isActive && $0.meetings?.contains(entry.id) == true && $0.children[entry.id] == nil
                                    ? $0.id : nil
                            }
                            if try await !provider.index.isCurrent(
                                entry.id, space: model.space, fingerprint: fingerprint) || batch != nil
                            {
                                pending += 1
                                let taskID = await self.queueSearchIndex(
                                    id: entry.id, revision: model.space + ":" + fingerprint,
                                    force: batch != nil, batchID: batch)
                                if let batch, let taskID, var request = controller.rebuildRequest,
                                    request.id == batch, request.isActive
                                {
                                    request.children[entry.id] = taskID
                                    try controller.saveRebuild(request)
                                }
                            }
                        }
                        cursor = entries.last
                    }
                    try await self.refreshSearchIndexRebuild()
                    if let request = controller.rebuildRequest, request.isActive {
                        controller.status = request.progress
                    }
                    else {
                        controller.status =
                            pending > 0
                            ? "\(pending) meetings need indexing. See Tasks for progress."
                            : "Search index is up to date."
                    }
                    controller.error = nil
                }
                catch SearchProviderError.sourceChanged {
                    controller.scanRequested = true
                    controller.scanRequestedAt = .now
                }
                catch {
                    if !Task.isCancelled { controller.error = error.localizedDescription }
                }
            }
        }
    }
    func performSearchIndex(id: UUID, providerID: UUID?) async throws {
        guard let selected = selectedSearchProvider, selected.id == providerID else { throw CancellationError() }
        guard !notesStorage.isEditing(id) else { throw CancellationError() }
        guard recordingID == nil, !isStartingRecording, !isFinalizingRecording else { throw CancellationError() }
        let provider = try await localSearch.indexingProvider(selected)
        defer {
            localSearch.progress = nil
            localSearch.indexingFinished()
        }
        let progress: @Sendable (SearchIndexProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.selectedSearchProvider == selected else { return }
                self.localSearch.progress = progress
                self.setJobProgress(
                    .searchIndex, .meeting(id), "Indexing passages: \(progress.completed) of \(progress.total)")
            }
        }
        if managedTasks.contains(where: {
            $0.kind == .searchIndex && $0.meetingID == id && $0.state == .running && $0.batchID != nil
        }) {
            try await provider.refreshIndex(meetingID: id, progress: progress)
        }
        else {
            try await provider.updateIndex(meetingID: id, rebuild: false, progress: progress)
        }
    }
}

extension AppSettings {
    var selectedSearchProvider: ServiceProvider? {
        serviceProviders.first {
            $0.id == searchProviderID && $0.kind == .localSearch && $0.supports(.search)
        }
    }

    mutating func selectSoleSearchProvider() {
        let eligible = serviceProviders.filter { $0.supports(.search) }
        if eligible.count == 1 { searchProviderID = eligible[0].id }
    }
}
