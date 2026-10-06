import Combine
import Foundation

@MainActor
final class LocalSearchController: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var loadingStage = ""
    @Published var status = "Choose a search model in Service Providers."
    @Published var progress: SearchIndexProgress?
    @Published var error: String?
    private var modelObservation: AnyCancellable?
    private var configured: ServiceProvider?
    private var current: SemanticSearchProvider?
    private var generation = UUID()
    private var preparation: Task<Void, Never>?
    var scanTask: Task<Void, Never>?
    var scanRequested = false
    var forceRebuild = false
    private let directory: URL
    private let indexDirectory: URL

    init(directory: URL, indexDirectory: URL) {
        self.directory = directory
        self.indexDirectory = indexDirectory
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
            index: index, encoder: CoreMLSemanticEmbedding(modelID: configuration.selectedModel, manager: .shared))
        current = result
        return result
    }
    func prepare(_ provider: ServiceProvider) async throws -> SemanticSearchProvider {
        if configured == provider, isReady, let current { return current }
        isLoading = true
        loadingStage = "Loading search index…"
        let result: SemanticSearchProvider
        do { result = try await self.provider(provider) }
        catch {
            isLoading = false
            throw error
        }
        let request = generation
        isLoading = true
        loadingStage = "Loading search model…"
        error = nil
        defer { if generation == request { isLoading = false } }
        do {
            try await result.prepare()
            guard generation == request else { throw CancellationError() }
            isReady = true
            loadingStage = "Search ready"
            return result
        }
        catch {
            if generation == request, !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }
    func preload(_ provider: ServiceProvider) {
        if configured == provider, isReady || isLoading { return }
        preparation?.cancel()
        preparation = Task { _ = try? await prepare(provider) }
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
        generation = UUID()
        preparation?.cancel()
        scanTask?.cancel()
        await preparation?.value
        await scanTask?.value
        if let current { await current.unload() }
        current = nil
        configured = nil
        isReady = false
        isLoading = false
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
            Task { await localSearch.shutdown() }
            return
        }
        if settings.automaticallyLoadSearch { localSearch.preload(provider) }
        scheduleSearchIndexing()
    }
    func scheduleSearchIndexing(rebuild: Bool = false) {
        let controller = localSearch
        controller.scanRequested = true
        controller.forceRebuild = controller.forceRebuild || rebuild
        guard controller.scanTask == nil, libraryWritable, !isPreparingToQuit, !isChangingLibrary,
            let libraryIndex
        else { return }
        controller.scanTask = Task { [weak self] in
            defer { controller.scanTask = nil }
            // Coalesce file notifications and finalized live-transcript checkpoints.
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            while controller.scanRequested, !Task.isCancelled {
                controller.scanRequested = false
                guard let self, !self.isPreparingToQuit, !self.isChangingLibrary,
                    let selected = self.selectedSearchProvider
                else { return }
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
                    let provider = try await controller.provider(selected)
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
        let provider = try await localSearch.prepare(selected)
        defer { localSearch.progress = nil }
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
