import AVFoundation
import Combine
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    deinit {
        let owner = processingRecordingOwner
        Task { await ProcessingCoordinator.shared.releaseOwner(owner) }
    }
    @Published var contextualChats: [String: [ChatMessage]] = [:] {
        didSet { if oldValue != contextualChats { chatsMutationRevision = UUID() } }
    }
    @Published var meetings: [Meeting] = [] {
        didSet {
            let previous = Dictionary(uniqueKeysWithValues: oldValue.map { ($0.id, $0) })
            let current = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
            invalidateExternalMeetingReloads(
                ids: Set(previous.keys).union(current.keys).filter { previous[$0] != current[$0] })
        }
    }
    @Published var meetingCatalog: [MeetingListEntry] = []
    @Published var visibleMeetingIDs: [UUID] = []
    @Published var latestCreatedMeetingID: UUID?
    @Published var isLoadingMeetingPage = false
    @Published var isSearchingMeetings = false
    @Published var meetingPageError: String?
    var previewPreparation: Task<Void, Never>?
    let summaryDrafts = SummaryDraftState()
    let meetingPrefetch = MeetingPrefetchState()
    var meetingPageHasMore = true
    @Published var meetingPageHasPrevious = false
    var libraryIndex: LibraryIndex?
    @Published var meetingIndexRevision = UUID()
    var directoryIndex: DirectoryIndex?
    @Published var directoryRevision = UUID()
    @Published var directoryIndexError: String?
    var indexNeedsInitialRebuild = false
    let libraryDataStatus = LibraryDataStatus()
    var libraryMonitor: LibraryMonitorCoordinator?
    private var pendingExternalChanges: ExternalLibraryChangeBatch?
    private var externalReloadTask: Task<Void, Never>?
    private var externalMeetingRevisions: [UUID: UUID] = [:]
    private var externalEventRevisions: [UUID: UUID] = [:]
    private var externalAncestorRevision = UUID()
    var externalReloadGeneration = UUID()
    var meetingLoadRequests: [UUID: UUID] = [:]
    var meetingLoadOperations: [UUID: MeetingLoadOperation] = [:]
    let meetingLoadQueue = MeetingLoadQueue()
    var meetingLoadReader: @Sendable (UUID, URL) throws -> Meeting = { id, directory in
        try MeetingFolderStorage.read(id: id, directory: directory)
    }
    var externalMeetingReader: @Sendable (UUID, URL) throws -> Meeting = {
        try MeetingFolderStorage.read(id: $0, directory: $1)
    }
    var meetingSearch = ""
    var meetingSearchGeneration = UUID()
    @Published var people: [Person] = [] { didSet { if oldValue != people { peopleMutationRevision = UUID() } } }
    @Published var tags: [MeetingTag] = [] { didSet { if oldValue != tags { tagsMutationRevision = UUID() } } }
    @Published var settings = AppSettings()
    @Published var providerLanguageStates: [ProviderLanguageIdentity: ProviderLanguageState] = [:]
    /// Saved language and model lists. providerLanguageStates holds only loading and failure.
    lazy var providerLanguageCache = ProviderMetadataCache<ProviderLanguageCatalog>(
        directory: dataDirectory, fileName: "languages.json",
        canWrite: { [unowned self] in self.canSave })
    lazy var providerModelCache = ProviderMetadataCache<[ProviderModel]>(
        directory: dataDirectory, fileName: "models.json",
        canWrite: { [unowned self] in self.canSave })
    var providerLanguageTasks: [ProviderLanguageIdentity: Task<ProviderResult<ProviderLanguageCatalog>, Error>] = [:]
    var providerLanguageLoader: @MainActor (ServiceProvider) async throws -> ProviderResult<ProviderLanguageCatalog> = {
        try await ProviderLanguageService.catalog(for: $0)
    }
    @Published var recordingID: UUID?
    @Published var presentsRecordingSetup = false
    /// Transcription, summaries, chat, archiving, and imports in progress; see
    /// BackgroundJobs.swift. Change only through beginJob and endJob. Jobs never
    /// block recording. Progress is transient: outcomes appear in the content
    /// itself, and failures use errorMessage.
    @Published var backgroundJobs: [BackgroundJob] = []
    var pendingJobProgress: [BackgroundJob.Key: String] = [:]
    var jobProgressUpdatedAt: [BackgroundJob.Key: ContinuousClock.Instant] = [:]
    var jobProgressFlush: Task<Void, Never>?
    @Published var managedTasks: [ManagedTaskRecord] = []
    @Published var managedTaskRevision = 0
    @Published var managedTasksLoading = false
    @Published var managedTaskAttentionCount = 0
    @Published var managedMaintenanceStateCounts: [ManagedTaskState: Int] = [:]
    @Published var managedTaskScopeCounts: [TaskHistoryScope: Int] = [:]
    @Published var managedTaskStateCounts: [ManagedTaskState: Int] = [:]
    @Published var managedTaskJournalError: String?
    var managedTaskIO = ManagedTaskIO()
    let managedTaskCommands = ManagedTaskCommands()
    var managedTaskPreparation: Task<Void, Never>?
    var managedTaskActiveCounts: [BackgroundJob.Key: Int] = [:]
    @Published var managedTaskReservations = Set<BackgroundJob.Key>()
    var managedTaskStopRequests = Set<UUID>()
    var managedMaintenancePauseRequests = Set<UUID>()
    @Published var isPreparingToQuit = false
    var managedTaskShutdownError: String?
    lazy var managedTaskJournal = ManagedTaskJournal(
        url: dataDirectory.appendingPathComponent("tasks.jsonl"),
        indexURL: indexDirectory.appendingPathComponent("index.db"))
    private var managedTaskWakeObserver: ManagedTaskWakeObserver?
    var processingRecordingGeneration: UInt64 = 0
    let processingRecordingOwner = UUID()
    var isSchedulingManagedTasks = false
    var managedTaskOperations: [UUID: Task<Void, Never>] = [:]
    var managedTaskWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    var transcriptionPollDelay: Duration = .seconds(2)
    /// Automatic completions coalesce to the newest saved transcript while a summary is running.
    var pendingAutomaticSummaries = Set<UUID>()
    var scheduledAutomaticSummaries = Set<UUID>()
    @Published var errorMessage: String?
    private var dataEventWarnings: AnyCancellable?
    @Published var recordingPermissionNeeded: RecordingPermission?
    /// Capture diagnostics text. Not shown in the interface, so it is not published:
    /// a change must not re-render every view observing the store.
    var captureHealth = ""
    @Published var recordingStartedAt: Date?
    @Published var isFinalizingRecording = false
    @Published private(set) var isStartingRecording = false
    /// 10 Hz meter state lives outside the store's publisher; only the meters observe it.
    let recordingMeter = RecordingMeterState()
    let liveTranscript = LiveTranscriptController()
    var recordingLevels: RecordingLevels { recordingMeter.levels }
    let dataDirectory: URL
    let indexDirectory: URL
    private var retiredVoiceSearchMigration: Task<Void, Never>?
    lazy var localSearch = LocalSearchController(directory: dataDirectory, indexDirectory: indexDirectory)

    @Published var isCopyingLibrary = false
    @Published var copiedLibraryFiles = 0
    @Published var pendingLibraryFolder: URL?
    @Published var libraryFolderError: String?
    var libraryCopyTask: Task<Void, Never>?
    let folderPreferences: LibraryFolderPreferences
    private var previousFolderPreference: Data?
    private var writableBeforeFolderChange = true
    var isChangingLibrary: Bool { isCopyingLibrary || pendingLibraryFolder != nil }
    var canChangeLibraryFolder: Bool {
        !isPreparingToQuit && voiceLibrary.isLoaded && voiceAssignmentRefreshCount == 0
            && !LocalModelManager.shared.isBusyExceptSearch && !localSearch.isLoading
            && !isChangingLibrary
            && recordingID == nil && !isStartingRecording
            && !isFinalizingRecording
            && !captureTransition && backgroundJobs.isEmpty && managedTaskOperations.isEmpty
            && !managedTasksLoading && managedTaskCommands.isIdle && managedTaskReservations.isEmpty
            && managedTaskStateCounts[.queued, default: 0] + managedTaskStateCounts[.running, default: 0] == 0
            && !managedTasks.contains(where: { $0.state.isActive })
    }
    lazy var notesStorage = NotesStorage(directory: dataDirectory)
    private var voiceAssignmentRefresh: Task<Void, Never>?
    private var voiceAssignmentRefreshRevision = UUID()
    @Published private var voiceAssignmentRefreshCount = 0
    lazy var voiceLibrary: VoiceLibraryStore = {
        let library = VoiceLibraryStore(
            loading: voiceLibraryLoading, directory: dataDirectory,
            canWrite: { [weak self] in self?.libraryWritable == true })
        library.didChange = { [weak self] ids in self?.scheduleVoiceAssignmentRefresh(meetingIDs: ids) }
        voiceReadinessObservation = library.$isLoaded.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        voiceJobObservation = library.$jobs.dropFirst().sink { [weak self] jobs in
            guard let self else { return }
            self.objectWillChange.send()
            let kind = BackgroundJob.Kind(rawValue: "voiceLibrary")
            if let job = jobs.first(where: { $0.state == .running || $0.state == .queued }) {
                if self.isJobRunning(kind, .library) {
                    self.setJobProgress(kind, .library, job.progress)
                }
                else {
                    _ = self.beginJob(kind, .library, progress: job.progress)
                }
            }
            else {
                self.endJob(kind, .library)
            }
        }
        return library
    }()
    private var voiceJobObservation: AnyCancellable?
    private var voiceReadinessObservation: AnyCancellable?
    private struct VoiceEnrollmentKey: Hashable {
        var meetingID: UUID
        var speakerID: UUID
    }
    private var voiceEnrollmentRequests: [VoiceEnrollmentKey: UUID] = [:]
    private let voiceLibraryLoading: VoiceLibraryStore.Loading
    lazy var voicePreparation = VoiceLibraryPreparation(
        library: voiceLibrary, people: { [weak self] in self?.people ?? [] })
    private var recorder: AudioCapture?
    private var captureTransition = false
    private var activeRecordingFormat: RecordingFormat = .opus
    private var peopleMutationRevision = UUID()
    private var tagsMutationRevision = UUID()
    private var chatsMutationRevision = UUID()
    private var canSave = true
    private var lastSavedLibrary = LibrarySnapshot()
    var libraryWritable: Bool { canSave }
    /// Derived from each meeting's server-archive.json; see ServerArchive.swift.
    @Published var archiveStatuses: [UUID: MeetingArchiveStatus] = [:]
    private let usesKeychain: Bool
    private var savedProviderKeys: [String: String] = [:]
    private var unreadableProviderKeys = Set<String>()
    var recordingDuration: TimeInterval { recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    /// Only the recording lifecycle and a read-only library prevent a new
    /// recording; background jobs for other meetings never do.
    var canStartRecording: Bool {
        !isPreparingToQuit && recordingID == nil && !isStartingRecording && !isFinalizingRecording
            && !captureTransition && canSave
    }

    init(voiceLibraryLoading: VoiceLibraryStore.Loading = .deferred, dataDirectory: URL? = nil) {
        self.voiceLibraryLoading = voiceLibraryLoading
        let dataDirectory =
            dataDirectory
            ?? ProcessInfo.processInfo.environment["GDAY_SWIFT_DATA_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        usesKeychain = dataDirectory == nil
        let folderPreferences = LibraryFolderPreferences(defaults: dataDirectory == nil ? .standard : nil)
        self.folderPreferences = folderPreferences
        let preferenceData = folderPreferences.data
        let preference = preferenceData.flatMap { try? JSONDecoder().decode(LibraryFolderPreference.self, from: $0) }
        self.dataDirectory =
            dataDirectory ?? (try? preference?.resolve())
            ?? preference.map { URL(fileURLWithPath: $0.path, isDirectory: true) } ?? LibraryLocation.directory()
        self.indexDirectory =
            preference == nil ? self.dataDirectory : LibraryFolderChoice.indexDirectory(for: self.dataDirectory)
        dataEventWarnings = NotificationCenter.default.publisher(for: DataEventJournal.writeFailure)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                guard let self, let folder = notification.object as? URL,
                    folder.path.hasPrefix(self.dataDirectory.path + "/")
                else { return }
                self.errorMessage =
                    "The file was saved, but its data event couldn’t be saved. Check the meeting folder’s permissions and available storage."
            }
        do {
            if preferenceData != nil && preference == nil {
                throw MeetingError.message(
                    "The saved data folder setting could not be read. Choose a folder in Settings → Data.")
            }
            if let preference { _ = try preference.resolve() }
            try FileManager.default.createDirectory(
                at: self.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try LibraryFileTransaction.recover(root: self.dataDirectory)
            indexNeedsInitialRebuild = !FileManager.default.fileExists(
                atPath: self.indexDirectory.appendingPathComponent("index.db").path)
            libraryIndex = try LibraryIndex(directory: self.dataDirectory, indexDirectory: self.indexDirectory)
            do {
                directoryIndex = try DirectoryIndex(root: self.dataDirectory, indexDirectory: self.indexDirectory)
            }
            catch {
                directoryIndexError = "Couldn’t open the directory index. \(error.localizedDescription)"
            }
            indexNeedsInitialRebuild = indexNeedsInitialRebuild || libraryIndex?.requiresRebuild == true
            let meetingFolders = FileManager.default.enumerator(
                at: self.dataDirectory.appendingPathComponent("meetings"), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            let hasMeetingFolders = meetingFolders?.nextObject() != nil
            indexNeedsInitialRebuild = indexNeedsInitialRebuild && hasMeetingFolders
            if !hasMeetingFolders { try libraryIndex?.markEmptyLibraryComplete() }
            people = try FileEntityStorage.load(Person.self, kind: "people", directory: self.dataDirectory)
            tags = try FileEntityStorage.load(MeetingTag.self, kind: "tags", directory: self.dataDirectory)
            let chatsURL = self.dataDirectory.appendingPathComponent("context-chats.json")
            if FileManager.default.fileExists(atPath: chatsURL.path) {
                contextualChats = try JSONDecoder().decode(
                    [String: [ChatMessage]].self, from: Data(contentsOf: chatsURL))
            }
            let settingsURL = self.dataDirectory.appendingPathComponent("settings.json")
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
            }
            for index in meetings.indices {
                // Keep existing speaker snapshots unchanged for resumable transcription jobs.
                for personID in meetings[index].speakers.compactMap(\.personID)
                where !meetings[index].personIDs.contains(personID) {
                    meetings[index].personIDs.append(personID)
                }
                notesStorage.saved[meetings[index].id] = meetings[index].notes
                // No editor undo session exists during startup. Keep conflict-copy assets too.
                let folder = directory(for: meetings[index].id)
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path) {
                    try? NotesImageClipboard.cleanupSaved(directory: folder, markdown: meetings[index].notes)
                }
            }
            notesStorage.onError = { [weak self] error in
                self?.errorMessage = "Couldn’t save meeting notes. \(error.localizedDescription)"
            }
            lastSavedLibrary = LibrarySnapshot(
                contextualChats: contextualChats, meetings: meetings, people: people, tags: tags)
            resetMeetingPages()
            refreshDirectoryIndex(rebuild: true)
            startLibraryMonitoring()
            refreshArchiveStatuses()
            if voiceLibraryLoading == .immediate {
                _ = voicePreparation
                Task { [weak self] in await self?.recoverUnadoptedLiveTranscripts() }
            }
            if usesKeychain {
                for index in settings.serviceProviders.indices {
                    let account = ProviderCredentialPersistence.account(for: settings.serviceProviders[index])
                    do {
                        let key = try KeychainStore.get(account) ?? ""
                        settings.serviceProviders[index].apiKey = key
                        savedProviderKeys[account] = key
                    }
                    catch {
                        unreadableProviderKeys.insert(account)
                        errorMessage = error.localizedDescription
                    }
                }
            }
            if FileManager.default.fileExists(atPath: self.dataDirectory.appendingPathComponent("tasks.jsonl").path) {
                managedTasksLoading = true
                managedTaskPreparation = Task { [weak self] in await self?.prepareManagedTasks() }
            }
            managedTaskWakeObserver = ManagedTaskWakeObserver { [weak self] in
                Task { await self?.recoverUnfinishedManagedTasks() }
            }
            do { try AgentGuides.ensure(directory: self.dataDirectory) }
            catch { errorMessage = "Couldn’t prepare the library’s AGENTS.md. \(error.localizedDescription)" }
        }
        catch {
            canSave = false
            errorMessage =
                "Could not open the local library. Existing files have been preserved. \(error.localizedDescription)"
        }
    }
    /// Called after the main window's initial update. Loading publishes saved
    /// jobs and decisions together without constructing a processing provider.
    func prepareVoiceLibraryAfterLaunch() async {
        if libraryWritable, retiredVoiceSearchMigration == nil, !isChangingLibrary, !isPreparingToQuit {
            let directory = dataDirectory
            let cache = indexDirectory
            retiredVoiceSearchMigration = Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                do {
                    try await LocalModelManager.shared.retireLegacyModels()
                    try RetiredVoiceSearchMigration.removeIndexNamespace(indexDirectory: cache)
                    try RetiredVoiceSearchMigration.removeArtifacts(directory: directory, indexDirectory: cache)
                }
                catch is CancellationError {}
                catch {
                    await MainActor.run {
                        self.errorMessage = "Couldn’t remove retired voice search data. \(error.localizedDescription)"
                    }
                }
                await MainActor.run { self.retiredVoiceSearchMigration = nil }
            }
        }
        await voiceLibrary.awaitLoaded()
        guard !isChangingLibrary, !isPreparingToQuit else { return }
        for id in meetings.map(\.id) where id != recordingID {
            guard let meeting = meeting(id: id) else { continue }
            let resolved = voiceLibrary.applyingDecisions(to: meeting)
            if resolved != meeting { _ = await updateMeeting(resolved) }
        }
        await recoverUnadoptedLiveTranscripts()
    }
    func changeLibraryFolder(to target: URL, copyCurrent: Bool) async {
        guard canChangeLibraryFolder else { return }
        libraryFolderError = nil
        writableBeforeFolderChange = canSave
        let copy: Task<Void, Error>?
        do {
            let kind = try LibraryFolderChoice.inspect(target, current: dataDirectory)
            guard copyCurrent ? kind == .empty : kind == .library else {
                throw MeetingError.message(
                    "Choose an empty folder to copy your library, or an existing library to open it.")
            }
            guard !copyCurrent || libraryWritable else {
                throw MeetingError.message("The current data folder is unavailable. Choose an existing library.")
            }
            retiredVoiceSearchMigration?.cancel()
            await retiredVoiceSearchMigration?.value
            if voiceLibrary.isLoaded { await voicePreparation.shutdown() }
            await localSearch.shutdown()
            try LocalModelManager.shared.suspendForLibraryChange()
            writableBeforeFolderChange = canSave
            previousFolderPreference = folderPreferences.data
            canSave = false
            externalReloadGeneration = UUID()
            isCopyingLibrary = true
            guard await flushCanonicalWrites() else {
                throw MeetingError.message("Save changes before changing the data folder.")
            }
            try await notesStorage.flushAll()
            copiedLibraryFiles = 0
            await libraryMonitor?.stop()
            libraryMonitor = nil
            let source = dataDirectory
            if copyCurrent {
                let report: @Sendable (Int) -> Void = { [weak self] count in
                    guard let self else { return }
                    Task { @MainActor in self.copiedLibraryFiles = count }
                }
                copy = Task.detached(priority: .utility) {
                    try LibraryFolderChoice.copyLibrary(from: source, to: target, progress: report)
                }
            }
            else {
                copy = nil
            }
            try await withTaskCancellationHandler {
                try await copy?.value
                try Task.checkCancellation()
            } onCancel: {
                copy?.cancel()
            }
            folderPreferences.data = try JSONEncoder().encode(LibraryFolderPreference(url: target))
            pendingLibraryFolder = target
            isCopyingLibrary = false
        }
        catch {
            LocalModelManager.shared.resumeAfterLibraryChange()
            isCopyingLibrary = false
            canSave = writableBeforeFolderChange && !canonicalRecoveryRequired
            if libraryMonitor == nil && canSave { startLibraryMonitoring() }
            if !(error is CancellationError) { libraryFolderError = error.localizedDescription }
        }
    }

    func cancelLibraryFolderChange() {
        if isCopyingLibrary {
            libraryCopyTask?.cancel()
            return
        }
        guard pendingLibraryFolder != nil else { return }
        folderPreferences.data = previousFolderPreference
        pendingLibraryFolder = nil
        LocalModelManager.shared.resumeAfterLibraryChange()
        canSave = writableBeforeFolderChange && !canonicalRecoveryRequired
        if canSave { startLibraryMonitoring() }
    }

    private var canonicalTail: Task<Bool, Never>?
    private var canonicalPending = 0
    private var canonicalRecoveryRequired = false
    var deletingMeetingIDs = Set<UUID>()
    var canonicalWriteHook: (@Sendable () throws -> Void)?

    private func enqueueCanonical(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = canonicalTail
        canonicalPending += 1
        let task = Task { @MainActor in
            _ = await previous?.value
            let result = canonicalRecoveryRequired ? false : await operation()
            canonicalPending -= 1
            return result
        }
        canonicalTail = task
        return await task.value
    }
    func flushCanonicalWrites() async -> Bool {
        var succeeded = true
        while canonicalPending > 0 {
            let result = await canonicalTail?.value ?? true
            succeeded = result && succeeded
        }
        return succeeded
    }

    @discardableResult private func save(personMerge: PersonMerge? = nil) async -> Bool {
        guard canSave else {
            errorMessage = "Library is read-only because loading failed. Check the data folder before saving changes."
            return false
        }
        invalidateExternalMeetingReloads(
            ids: Set(meetings.filter { !lastSavedLibrary.meetings.contains($0) }.map(\.id)))
        return await enqueueCanonical { await self.performCanonicalSave(personMerge: personMerge) }
    }

    private func performCanonicalSave(
        personMerge: PersonMerge? = nil, artifacts: [CanonicalMeetingArtifact] = [],
        validateInputs: (@Sendable () throws -> Void)? = nil
    ) async -> Bool {
        guard !canonicalRecoveryRequired else { return false }
        for index in meetings.indices {
            let previous = lastSavedLibrary.meetings.first { $0.id == meetings[index].id }
            if previous != meetings[index] {
                meetings[index] = MeetingSpeakerColors.assigning(meetings[index], previous: previous)
            }
        }
        let captured = LibrarySnapshot(contextualChats: contextualChats, meetings: meetings, people: people, tags: tags)
        let baseline = lastSavedLibrary
        let revisions = externalMeetingRevisions
        let peopleRevision = peopleMutationRevision
        let tagsRevision = tagsMutationRevision
        let chatsRevision = chatsMutationRevision
        let noteRevisions = Dictionary(
            uniqueKeysWithValues: captured.meetings.map { ($0.id, notesStorage.revision($0.id)) })
        let changed = captured.meetings.filter { !baseline.meetings.contains($0) }
        var voice: VoiceLibraryStore.CanonicalCommit?
        var result: CanonicalLibraryResult
        do {
            voice = try voiceLibrary.beginCanonicalCommit()
            try await notesStorage.flushAll()
            for meeting in changed where notesStorage.saved[meeting.id] != meeting.notes {
                guard notesStorage.revision(meeting.id) == noteRevisions[meeting.id] else { continue }
                try await notesStorage.write(meeting.id, text: meeting.notes)
            }
            let command = CanonicalLibraryWrite(
                current: captured, previous: baseline, directory: dataDirectory,
                recordingID: recordingID, personMerge: personMerge, index: libraryIndex,
                indexIsBuilding: libraryDataStatus.isBuilding, voice: voice,
                artifacts: artifacts, validateInputs: validateInputs)
            let hook = canonicalWriteHook
            result = await Task.detached(priority: .utility) {
                do { try hook?() }
                catch { return CanonicalLibraryResult(committed: false, error: error.localizedDescription) }
                return CanonicalLibraryWriter.write(command)
            }.value
        }
        catch { result = CanonicalLibraryResult(committed: false, error: error.localizedDescription) }
        voiceLibrary.finishCanonicalCommit(
            voice, state: result.voiceState, committed: result.committed,
            refreshFailed: result.voiceStateRefreshFailed || result.requiresRecovery)
        if result.requiresRecovery {
            canonicalRecoveryRequired = true
            canSave = false
            errorMessage = result.error
            return false
        }
        if result.committed {
            let loaded = Set(meetings.map(\.id))
            let changedIDs = Set(changed.map(\.id))
            lastSavedLibrary.meetings =
                lastSavedLibrary.meetings.filter {
                    loaded.contains($0.id) && !changedIDs.contains($0.id)
                } + changed.filter { loaded.contains($0.id) }
            if captured.people != baseline.people { lastSavedLibrary.people = captured.people }
            if captured.tags != baseline.tags { lastSavedLibrary.tags = captured.tags }
            if captured.contextualChats != baseline.contextualChats {
                lastSavedLibrary.contextualChats = captured.contextualChats
            }
            if let warning = result.warning { errorMessage = warning }
            if let error = result.indexError { libraryDataStatus.error = error }
            if !result.changedPaths.isEmpty {
                meetingIndexRevision = UUID()
                libraryMonitor?.process(.init(paths: result.changedPaths, requiresScan: false, eventID: 0))
            }
            refreshDirectoryIndex(previousPeople: baseline.people, previousTags: baseline.tags)
            if Set(baseline.tags.filter(\.isExcluded).map(\.id)) != excludedTagIDs {
                resetMeetingPages()
            }
            else {
                await refreshMeetingPagesAfterSave(previousIDs: [])
            }
            return true
        }
        // Roll back only values still owned by this command. Later edits remain dirty.
        let proposed = Dictionary(uniqueKeysWithValues: captured.meetings.map { ($0.id, $0) })
        let previous = Dictionary(uniqueKeysWithValues: baseline.meetings.map { ($0.id, $0) })
        meetings = meetings.compactMap { current in
            guard proposed[current.id] == current, revisions[current.id] == externalMeetingRevisions[current.id] else {
                return current
            }
            guard var old = previous[current.id] else { return nil }
            old.notes = notesStorage.pending[old.id] ?? notesStorage.saved[old.id] ?? old.notes
            return old
        }
        if peopleMutationRevision == peopleRevision { people = baseline.people }
        if tagsMutationRevision == tagsRevision { tags = baseline.tags }
        if chatsMutationRevision == chatsRevision { contextualChats = baseline.contextualChats }
        errorMessage = "Couldn’t save changes. " + (result.error ?? "Try again.")
        return false
    }
    /// Call when a persistence command is admitted, before it yields to its worker.
    func invalidateExternalMeetingReloads(ids: Set<UUID>) {
        let loaded = Set(meetings.map(\.id))
        for id in ids where loaded.contains(id) { externalMeetingRevisions[id] = UUID() }
        externalMeetingRevisions = externalMeetingRevisions.filter { loaded.contains($0.key) }
        externalEventRevisions = externalEventRevisions.filter { loaded.contains($0.key) }
    }

    func requestExternalLibraryReload(paths: [URL], rebuild: Bool) {
        let incoming = ExternalLibraryChangeBatch(paths: paths, root: dataDirectory, rebuild: rebuild)
        guard !incoming.changes.isEmpty else { return }
        if let ids = incoming.meetingIDs {
            for id in ids { meetingLoadRequests.removeValue(forKey: id) }
            for id in ids where meetings.contains(where: { $0.id == id }) { externalEventRevisions[id] = UUID() }
        }
        else {
            externalAncestorRevision = UUID()
            meetingLoadRequests.removeAll()
        }
        if pendingExternalChanges == nil {
            pendingExternalChanges = incoming
        }
        else {
            pendingExternalChanges?.formUnion(incoming)
        }
        guard externalReloadTask == nil else { return }
        externalReloadTask = Task { [weak self] in
            guard let self else { return }
            defer { externalReloadTask = nil }
            while let changes = pendingExternalChanges {
                pendingExternalChanges = nil
                guard !isChangingLibrary else { continue }
                let generation = externalReloadGeneration
                let completed = await reloadExternalLibraryDocuments(batch: changes)
                if !completed, !isChangingLibrary {
                    if pendingExternalChanges == nil {
                        pendingExternalChanges = changes
                    }
                    else {
                        pendingExternalChanges?.formUnion(changes)
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
                if completed, generation == externalReloadGeneration, !isChangingLibrary,
                    changes.changes.contains(.tasks)
                {
                    await reloadExternalManagedTasks()
                }
            }
        }
    }

    @discardableResult
    func reloadExternalLibraryDocuments(reloadCatalogs: Bool = true) async -> Bool {
        var batch = ExternalLibraryChangeBatch(root: dataDirectory, rebuild: true)
        batch.changes = reloadCatalogs ? [.meetings, .people, .tags] : [.meetings]
        return await reloadExternalLibraryDocuments(batch: batch)
    }

    private func canReloadExternalMeeting(_ meeting: Meeting) -> Bool {
        notesStorage.pending[meeting.id] == nil
            && lastSavedLibrary.meetings.first(where: { $0.id == meeting.id }) == meeting
            && !backgroundJobs.contains(where: { $0.meetingID == meeting.id })
            && recordingID != meeting.id
    }

    private func reloadExternalLibraryDocuments(batch: ExternalLibraryChangeBatch) async -> Bool {
        guard !isChangingLibrary else { return true }
        let root = dataDirectory
        let generation = externalReloadGeneration
        let ancestorRevision = externalAncestorRevision
        let eventRevisions = externalEventRevisions
        let originals = meetings.filter {
            batch.changes.contains(.meetings) && (batch.meetingIDs?.contains($0.id) ?? true)
                && canReloadExternalMeeting($0)
        }
        let revisions = externalMeetingRevisions
        let originalPeople = people
        let originalTags = tags
        let originalPeopleRevision = peopleMutationRevision
        let originalTagsRevision = tagsMutationRevision
        let originalNotes = notesStorage.saved
        let noteRevisions = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, notesStorage.revision($0.id)) })
        let reader = externalMeetingReader
        let result = await Task.detached(priority: .utility) {
            let catalog: ExternalCatalogSnapshot?
            var catalogError: String?
            do { catalog = try ExternalCatalogSnapshot.read(changes: batch.changes, directory: root) }
            catch {
                catalogError = error.localizedDescription
                catalog = ExternalCatalogSnapshot(people: nil, tags: nil)
            }
            let snapshot = ExternalMeetingSnapshot.read(ids: Set(originals.map(\.id)), directory: root, reader: reader)
            return (catalog, snapshot, catalogError)
        }.value
        guard !Task.isCancelled, generation == externalReloadGeneration, root == dataDirectory, !isChangingLibrary
        else { return true }
        guard let catalogs = result.0, let snapshot = result.1 else { return false }
        if let error = result.2 ?? snapshot.errors.first { libraryDataStatus.error = error }
        if let fresh = catalogs.people, peopleMutationRevision == originalPeopleRevision,
            people == originalPeople, lastSavedLibrary.people == originalPeople
        {
            if people != fresh { people = fresh }
            lastSavedLibrary.people = fresh
        }
        let previousExcluded = excludedTagIDs
        if let fresh = catalogs.tags, tagsMutationRevision == originalTagsRevision,
            tags == originalTags, lastSavedLibrary.tags == originalTags
        {
            if tags != fresh { tags = fresh }
            lastSavedLibrary.tags = fresh
        }
        for original in originals {
            let id = original.id
            guard ancestorRevision == externalAncestorRevision, eventRevisions[id] == externalEventRevisions[id],
                revisions[id] == externalMeetingRevisions[id],
                let position = meetings.firstIndex(where: { $0.id == id }), meetings[position] == original,
                canReloadExternalMeeting(original), notesStorage.saved[id] == originalNotes[id],
                notesStorage.revision(id) == noteRevisions[id]
            else { continue }
            if snapshot.removed.contains(id) {
                meetings.remove(at: position)
                lastSavedLibrary.meetings.removeAll { $0.id == id }
                notesStorage.saved.removeValue(forKey: id)
                archiveStatuses.removeValue(forKey: id)
            }
            else if let fresh = snapshot.meetings[id] {
                if meetings[position] != fresh { meetings[position] = fresh }
                if let saved = lastSavedLibrary.meetings.firstIndex(where: { $0.id == id }) {
                    lastSavedLibrary.meetings[saved] = fresh
                }
            }
        }
        if previousExcluded != excludedTagIDs {
            resetMeetingPages()
        }
        else {
            await refreshMeetingPagesAfterSave(previousIDs: [])
        }
        refreshMeetingPageAvailabilityAfterIndexCommit()
        return true
    }
    func evictLoadedMeetings(keeping id: UUID) {
        guard meetings.count > 24 else { return }
        let protected = Set(
            backgroundJobs.compactMap(\.meetingID) + [recordingID, id].compactMap { $0 }
                + Array(notesStorage.pending.keys))
        let candidates = meetings.filter { !protected.contains($0.id) && lastSavedLibrary.meetings.contains($0) }
        let ids = Set(candidates.prefix(meetings.count - 24).map(\.id))
        meetings.removeAll { ids.contains($0.id) }
        lastSavedLibrary.meetings.removeAll { ids.contains($0.id) }
        for id in ids { notesStorage.saved.removeValue(forKey: id) }
    }
    func rememberLoadedMeeting(_ meeting: Meeting) {
        lastSavedLibrary.meetings.append(meeting)
    }
    /// Preview uses this only after saving its synthetic fixtures.
    func clearLoadedMeetingCache() {
        guard recordingID == nil, backgroundJobs.isEmpty else { return }
        externalReloadGeneration = UUID()
        meetings = []
        lastSavedLibrary.meetings = []
    }
    @discardableResult func saveContextChat(key: String, messages: [ChatMessage]) async -> Bool {
        guard canSave else { return false }
        contextualChats[key] = messages
        return await save()
    }
    @discardableResult func saveSettings() -> Bool {
        guard canSave else {
            errorMessage = "Restore the local library before changing settings."
            return false
        }
        settings.selectSoleSearchProvider()
        do {
            let settingsData = try JSONEncoder().encode(settings)
            let persist = {
                try ProviderCredentialPersistence.writeSettings(
                    settingsData, to: self.dataDirectory.appendingPathComponent("settings.json"))
            }
            if usesKeychain {
                // Read failed credentials before changing any item, including keys
                // belonging to providers removed from the draft settings.
                var previous = savedProviderKeys
                for account in unreadableProviderKeys {
                    previous[account] = try KeychainStore.get(account) ?? ""
                }
                var next: [String: String] = [:]
                for provider in settings.serviceProviders {
                    let account = ProviderCredentialPersistence.account(for: provider)
                    if unreadableProviderKeys.contains(account), provider.apiKey.isEmpty {
                        next[account] = previous[account]
                    }
                    else {
                        next[account] = provider.apiKey
                    }
                }
                try ProviderCredentialPersistence.save(
                    previous: previous, next: next,
                    write: { try KeychainStore.set($1, for: $0) },
                    remove: { try KeychainStore.delete($0) }, persistSettings: persist)
                savedProviderKeys = next
                unreadableProviderKeys.removeAll()
                for index in settings.serviceProviders.indices {
                    let account = ProviderCredentialPersistence.account(for: settings.serviceProviders[index])
                    settings.serviceProviders[index].apiKey = next[account] ?? ""
                }
            }
            else {
                try persist()
            }
        }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
        ProviderHealthStore.shared.invalidateChangedConfiguration(settings: settings)
        searchConfigurationChanged()
        return true
    }
    func insertImportedMeeting(_ meeting: Meeting) async throws {
        guard canSave else { throw MeetingError.message("The library is read-only because loading failed.") }
        meetings.insert(meeting, at: 0)
        guard await save() else { throw MeetingError.message(errorMessage ?? "Could not save imported meeting.") }
        latestCreatedMeetingID = meeting.id
    }
    @discardableResult func createMeeting(title: String = "Untitled Meeting", language: String? = nil) async -> UUID {
        guard canSave else { return UUID() }
        let meeting = Meeting(title: title, language: language ?? settings.defaultLanguage)
        do {
            _ = try MeetingFolderLocation.newFolder(id: meeting.id, date: meeting.createdAt, directory: dataDirectory)
        }
        catch {
            errorMessage = error.localizedDescription
            return meeting.id
        }
        meetings.insert(meeting, at: 0)
        if await save() { latestCreatedMeetingID = meeting.id }
        return meeting.id
    }
    @discardableResult func updateMeeting(_ meeting: Meeting) async -> Bool {
        _ = await ensureMeetingLoaded(id: meeting.id)
        guard canSave, !deletingMeetingIDs.contains(meeting.id),
            let index = meetings.firstIndex(where: { $0.id == meeting.id })
        else { return false }
        meetings[index] = meeting
        return await save()
    }
    func hasCommittedTaskReceipt(_ task: ManagedTaskRecord) -> Bool {
        lastSavedLibrary.meetings.first { $0.id == task.meetingID }?
            .completedTaskIDs[task.kind.rawValue] == task.id
    }

    /// Serialize prepared speaker publication with ordinary meeting/voice changes.
    /// The existing canonical writer rolls back files and in-memory state together.
    func commitSpeakerConsolidation(
        expected: Meeting, updated: Meeting, examples: [VoiceExample], artifacts: [CanonicalMeetingArtifact],
        validateInputs: @escaping @Sendable () throws -> Void
    ) async -> Bool {
        guard libraryWritable, !Task.isCancelled else { return false }
        return await enqueueCanonical { [self] in
            guard libraryWritable, !deletingMeetingIDs.contains(expected.id),
                let index = meetings.firstIndex(where: { $0.id == expected.id })
            else { return false }
            let current = meetings[index]
            guard current.audioFiles == expected.audioFiles, current.transcriptSource == expected.transcriptSource,
                current.transcript == expected.transcript, current.speakers == expected.speakers
            else {
                errorMessage =
                    "The meeting changed while speaker labeling was running. Run it again for the current transcript."
                return false
            }
            // Review may have changed while this command waited for another save.
            let reviewed = voiceLibrary.applyingDecisions(to: updated)
            guard voiceLibrary.upsert(examples, staged: true) else {
                errorMessage = voiceLibrary.errorMessage
                return false
            }
            // Preserve unrelated edits made while this command waited in the queue.
            var next = current
            next.transcript = reviewed.transcript
            next.replaceSpeakers(reviewed.speakers)
            next.speakerLabelSource = updated.speakerLabelSource
            next.completedTaskIDs[BackgroundJob.Kind.diarization.rawValue] =
                updated.completedTaskIDs[BackgroundJob.Kind.diarization.rawValue]
            meetings[index] = next
            invalidateExternalMeetingReloads(ids: [expected.id])
            return await performCanonicalSave(artifacts: artifacts, validateInputs: validateInputs)
        }
    }

    @discardableResult func deleteMeeting(id: UUID) async -> Bool {
        await voiceLibrary.awaitLoaded()
        guard canSave else { return false }
        guard
            !voiceLibrary.jobs.contains(where: { job in
                (job.state == .running || job.state == .queued)
                    && (job.discoveryInputs.contains { $0.meetingID == id }
                        || job.exampleIDs.contains(where: { sampleID in
                            voiceLibrary.examples.contains { $0.id == sampleID && $0.meetingID == id }
                        }))
            })
        else {
            errorMessage = "Pause voice preparation before deleting this meeting."
            return false
        }
        guard recordingID != id else {
            errorMessage = "Stop recording before deleting this meeting."
            return false
        }
        guard !backgroundJobs.contains(where: { $0.meetingID == id }) else {
            errorMessage = "Wait for this meeting’s background tasks to finish before deleting it."
            return false
        }
        guard deletingMeetingIDs.insert(id).inserted else { return false }
        meetingLoadRequests.removeValue(forKey: id)
        invalidateExternalMeetingReloads(ids: [id])
        defer { deletingMeetingIDs.remove(id) }
        return await enqueueCanonical {
            guard self.notesStorage.reserveDeletion(id) else { return false }
            defer { self.notesStorage.releaseDeletion(id) }
            do {
                try await self.notesStorage.flush(id)
                let root = self.dataDirectory
                let index = self.libraryIndex
                let indexError = try await Task.detached(priority: .utility) {
                    let folder = try MeetingFolderLocation.resolve(id: id, directory: root)
                    if FileManager.default.fileExists(atPath: folder.path) {
                        _ = try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                    }
                    do {
                        try index?.remove(id: id)
                        return Optional<String>.none
                    }
                    catch { return error.localizedDescription }
                }.value
                self.meetings.removeAll { $0.id == id }
                self.lastSavedLibrary.meetings.removeAll { $0.id == id }
                self.meetingCatalog.removeAll { $0.id == id }
                self.visibleMeetingIDs.removeAll { $0 == id }
                await self.localSearch.removeMeeting(id)
                do { try await self.notesStorage.discard(id) }
                catch {
                    self.errorMessage =
                        "The meeting was moved to Trash, but its notes state couldn’t be cleared. "
                        + error.localizedDescription
                }
                if let indexError {
                    self.libraryDataStatus.error =
                        "The meeting was moved to Trash, but its index couldn’t be updated. " + indexError
                }
                self.meetingIndexRevision = UUID()
                await self.refreshMeetingPagesAfterSave(previousIDs: [])
                return true
            }
            catch {
                self.errorMessage = error.localizedDescription
                return false
            }
        }
    }
    @discardableResult func addPerson(name: String) async -> UUID {
        guard canSave else { return UUID() }
        let person = Person(name: name)
        people.append(person)
        await save()
        return person.id
    }
    func updatePerson(_ person: Person) async {
        guard canSave else { return }
        if let i = people.firstIndex(where: { $0.id == person.id }) {
            people[i] = person
            await save()
        }
    }
    var canMergePeople: Bool {
        canSave && canonicalPending == 0 && canChangeLibraryFolder && !libraryDataStatus.isBuilding
            && !indexNeedsInitialRebuild
            && libraryIndex != nil
    }

    @discardableResult
    func mergePerson(id: UUID, into targetID: UUID) async -> Bool {
        await mergePeople(ids: [id, targetID], into: targetID)
    }

    @discardableResult
    func mergePeople(ids: Set<UUID>, into targetID: UUID) async -> Bool {
        guard await voiceLibrary.awaitReady() else {
            errorMessage = voiceLibrary.errorMessage
            return false
        }
        guard canMergePeople else {
            errorMessage = "Wait for recording, processing, and indexing to finish before merging people."
            return false
        }
        guard ids.count > 1, ids.contains(targetID), ids.isSubset(of: Set(people.map(\.id))),
            let targetIndex = people.firstIndex(where: { $0.id == targetID })
        else {
            errorMessage = "Select at least two people and choose one to keep."
            return false
        }
        let sourceIDs = ids.subtracting([targetID])
        let sources = people.filter { sourceIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let merge = PersonMerge(sourceIDs: sourceIDs, targetID: targetID)
        guard voiceLibrary.mergePeople(ids: sourceIDs, into: targetID, staged: true) else {
            errorMessage = voiceLibrary.errorMessage ?? "Couldn’t update voice samples."
            return false
        }
        for source in sources { people[targetIndex] = PersonMerge.combining(source, into: people[targetIndex]) }
        people.removeAll { sourceIDs.contains($0.id) }
        for index in meetings.indices { merge.apply(to: &meetings[index]) }
        let targetKey = Self.contextChatKey(personID: targetID)
        for source in sources {
            let sourceKey = Self.contextChatKey(personID: source.id)
            if let messages = contextualChats.removeValue(forKey: sourceKey) {
                var combined = contextualChats[targetKey] ?? []
                for message in messages where !combined.contains(where: { $0.id == message.id }) {
                    combined.append(message)
                }
                contextualChats[targetKey] = combined.sorted { $0.createdAt < $1.createdAt }
            }
        }
        return await save(personMerge: merge)
    }

    func deletePerson(id: UUID) async {
        guard await voiceLibrary.awaitReady() else {
            errorMessage = voiceLibrary.errorMessage
            return
        }
        guard await flushCanonicalWrites() else { return }
        guard canSave, await removeRelationships(personID: id) else { return }
        guard voiceLibrary.removePerson(id: id, staged: true) else {
            errorMessage = voiceLibrary.errorMessage
            return
        }
        people.removeAll { $0.id == id }
        contextualChats.removeValue(forKey: Self.contextChatKey(personID: id))
        await save()
    }
    private func removeRelationships(personID: UUID? = nil, tagID: UUID? = nil) async -> Bool {
        guard !indexNeedsInitialRebuild else {
            errorMessage = "Wait for the initial index build before deleting people or tags."
            return false
        }
        do {
            var cursor: MeetingListEntry?
            while true {
                let indexed = try libraryIndex?.page(after: cursor, limit: 20, personID: personID, tagID: tagID) ?? []
                var candidates = Dictionary(uniqueKeysWithValues: indexed.map { ($0.id, $0) })
                for meeting in meetings {
                    let entry = MeetingListEntry(meeting)
                    guard cursor.map({ MeetingListEntry.newestFirst($0, entry) }) ?? true else { continue }
                    let matches =
                        personID.map { entry.personIDs.contains($0) } ?? tagID.map { entry.tagIDs.contains($0) }
                        ?? false
                    if matches {
                        candidates[entry.id] = entry
                    }
                    else {
                        candidates.removeValue(forKey: entry.id)
                    }
                }
                let page = Array(candidates.values.sorted(by: MeetingListEntry.newestFirst).prefix(20))
                if page.isEmpty {
                    if let last = indexed.last {
                        cursor = last
                        continue
                    }
                    return true
                }
                for entry in page {
                    guard await ensureMeetingLoaded(id: entry.id),
                        let position = meetings.firstIndex(where: { $0.id == entry.id })
                    else { return false }
                    if let personID {
                        meetings[position].personIDs.removeAll { $0 == personID }
                        for speaker in meetings[position].speakers.indices
                        where meetings[position].speakers[speaker].personID == personID {
                            meetings[position].speakers[speaker].personID = nil
                            meetings[position].speakers[speaker].confidence = nil
                            meetings[position].speakers[speaker].confirmed = false
                        }
                    }
                    if let tagID { meetings[position].tagIDs.removeAll { $0 == tagID } }
                }
                guard await save() else { return false }
                cursor = page.last
            }
        }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    @discardableResult func addTag(name: String, color: String = "blue") async -> UUID {
        guard canSave else { return UUID() }
        let tag = MeetingTag(name: name, color: color)
        tags.append(tag)
        await save()
        return tag.id
    }
    var excludedTagIDs: Set<UUID> { Set(tags.filter(\.isExcluded).map(\.id)) }
    var listedPeople: [Person] {
        let excluded = excludedTagIDs
        return people.filter { excluded.isDisjoint(with: $0.tagIDs) }
    }
    func updateTag(_ tag: MeetingTag) async {
        guard canSave else { return }
        if let i = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[i] = tag
            await save()
        }
    }
    func deleteTag(id: UUID) async {
        guard canSave, await removeRelationships(tagID: id) else { return }
        tags.removeAll { $0.id == id }
        for index in people.indices { people[index].tagIDs.removeAll { $0 == id } }
        contextualChats.removeValue(forKey: Self.contextChatKey(tagID: id))
        await save()
    }
    func directory(for id: UUID) -> URL { MeetingFolderStorage.folder(id: id, directory: dataDirectory) }
    func audioURLs(for meeting: Meeting) -> [URL] {
        meeting.audioFiles.filter { URL(fileURLWithPath: $0).lastPathComponent == $0 && $0 != "." && $0 != ".." }.map {
            directory(for: meeting.id).appendingPathComponent($0)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func audioURL(for meeting: Meeting) -> URL? { audioURLs(for: meeting).first }

    func startRecording(
        title: String? = nil, language: String? = nil, microphoneEnabled: Bool? = nil, systemEnabled: Bool? = nil,
        format: RecordingFormat? = nil
    ) async {
        guard !UIPreview.enabled else {
            errorMessage = "Recording is disabled in UI Preview."
            return
        }
        guard canStartRecording else { return }
        let microphone = microphoneEnabled ?? settings.captureMicrophone
        let systemAudio = systemEnabled ?? settings.captureSystemAudio
        isStartingRecording = true
        defer {
            isStartingRecording = false
            if recordingID == nil {
                resumeSearchIndexingAfterRecording()
                if voiceLibrary.isLoaded, !isPreparingToQuit, !isChangingLibrary {
                    voicePreparation.resumeAfterRecording(directory: directory(for:))
                }
            }
        }
        await suspendSearchIndexingForRecording()
        if voiceLibrary.isLoaded { voicePreparation.suspendForRecording() }
        recordingMeter.reset(
            RecordingLevels(
                microphone: RecordingSourceLevel(enabled: microphone),
                system: RecordingSourceLevel(enabled: systemAudio)))
        recordingPermissionNeeded = nil
        captureTransition = true
        activeRecordingFormat = format ?? settings.recordingFormat
        let suppliedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let meeting = Meeting(
            title: suppliedTitle.isEmpty ? Date().formatted(date: .abbreviated, time: .shortened) : suppliedTitle,
            language: language ?? settings.defaultLanguage)
        do {
            let folder = try MeetingFolderLocation.newFolder(
                id: meeting.id, date: meeting.createdAt, directory: dataDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let capture = AudioCapture()
            let liveSink = LiveAudioSink()
            capture.liveAudioSink = liveSink
            capture.onLevels = { [weak self] levels, delivered in
                Task { @MainActor in
                    defer { delivered() }
                    if let self, self.recordingID == meeting.id && !self.isFinalizingRecording {
                        // A meter snapshot queued before a click must not undo
                        // the source state already applied to the writer.
                        var current = levels
                        current.microphone.muted = self.recordingMeter.levels.microphone.muted
                        current.system.muted = self.recordingMeter.levels.system.muted
                        self.recordingMeter.deliver(current)
                    }
                }
            }
            capture.onHealth = { [weak self] message in
                Task { @MainActor in if self?.recordingID == meeting.id { self?.captureHealth = message } }
            }
            capture.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    while self.captureTransition { try? await Task.sleep(nanoseconds: 100_000_000) }
                    guard self.recordingID == meeting.id else { return }
                    self.errorMessage = error.localizedDescription
                    await self.stopRecording(transcribeAfter: false)
                }
            }
            let files = try await capture.start(
                directory: directory(for: meeting.id), microphoneEnabled: microphone,
                systemEnabled: systemAudio,
                voiceProcessing: settings.automaticVoiceProcessing ? .automatic : .off,
                microphoneDevice: settings.microphoneDevice, format: activeRecordingFormat)
            var recorded = meeting
            recorded.audioFiles = files
            recorded.recordingProfile = capture.profile
            meetings.insert(recorded, at: 0)
            guard await save() else {
                try? await capture.stop()
                throw MeetingError.message(errorMessage ?? "Could not save recording metadata.")
            }
            latestCreatedMeetingID = meeting.id
            recorder = capture
            recordingID = meeting.id
            recordingStartedAt = Date()
            liveTranscript.begin(
                meetingID: meeting.id, language: meeting.language, directory: directory(for: meeting.id),
                sources: [microphone ? .microphone : nil, systemAudio ? .system : nil].compactMap { $0 },
                sink: liveSink, enabled: settings.liveTranscriptionEnabled,
                diarizationProvider: settings.serviceProviders.first {
                    $0.id == settings.liveDiarizationProviderID && $0.supports(.liveDiarization)
                },
                speakerLabelsEnabled: settings.showLiveSpeakerLabels,
                speakerRecognitionEnabled: settings.recognizeLiveSpeakers,
                people: { [weak self] in self?.people ?? [] },
                enrollVoice: { [weak self] personID, speakerID, embedding in
                    Task {
                        await self?.enrollLiveVoice(
                            meetingID: meeting.id, personID: personID,
                            speakerID: speakerID, embedding: embedding)
                    }
                },
                recordVoice: { [weak self] sample, embedding in
                    await self?.recordVoiceExample(meetingID: meeting.id, sample: sample, embedding: embedding)
                })
            captureHealth = [
                microphone
                    ? (capture.profile.microphoneVoiceProcessing
                        ? "Microphone: Apple voice processing" : "Microphone: unprocessed") : nil,
                systemAudio ? "System audio: separate track" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        }
        catch {
            if error is CancellationError {
                // Cancelling is deliberate, so it needs no notice.
            }
            else if let permission = RecordingPermissions.permission(for: error) {
                recordingPermissionNeeded = permission
            }
            else {
                errorMessage = error.localizedDescription
            }
        }
        captureTransition = false
    }
    /// The live Voice Processing switch; explicit for the rest of the recording.
    func setRecordingVoiceProcessing(_ enabled: Bool) { recorder?.setVoiceProcessing(enabled) }
    func toggleRecordingMute(microphone: Bool) {
        guard recordingID != nil, !isFinalizingRecording, recorder != nil || UIPreview.enabled else { return }
        var levels = recordingMeter.levels
        let source = microphone ? levels.microphone : levels.system
        guard source.enabled else { return }
        recorder?.setMuted(!source.muted, microphone: microphone)
        if microphone {
            levels.microphone.muted.toggle()
        }
        else {
            levels.system.muted.toggle()
        }
        recordingMeter.deliver(levels)
    }
    func stopRecording(transcribeAfter: Bool = true) async {
        _ = await flushNotes()
        guard let id = recordingID else { return }
        guard !captureTransition else { return }
        captureTransition = true
        isFinalizingRecording = true
        let duration = recordingDuration
        var stopFailed = false
        do { try await recorder?.stop() }
        catch {
            // An empty source is not a failed recording; its message names the
            // source and says which track was saved.
            errorMessage =
                (error as? CaptureSourceError)?.isNoAudio == true
                ? error.localizedDescription
                : "Couldn’t finish the recording. Audio captured before the problem is kept in this meeting. \(error.localizedDescription)"
            stopFailed = true
        }
        if !stopFailed, let meeting = meeting(id: id) {
            for name in meeting.audioFiles {
                do {
                    let folder = directory(for: id)
                    try DataEventJournal.fileSaved(
                        folder.appendingPathComponent(name), action: .modified, directory: folder)
                }
                catch {
                    errorMessage =
                        "Audio was saved, but its data event couldn’t be saved. \(error.localizedDescription)"
                }
            }
        }
        await liveTranscript.finish()
        let profile = recorder?.profile
        recorder = nil
        captureHealth = ""
        if let index = meetings.firstIndex(where: { $0.id == id }) {
            meetings[index].duration = duration
            meetings[index].recordingProfile = profile
            if !(await save()) { stopFailed = true }
        }
        if !stopFailed && activeRecordingFormat == .m4a {
            do { try await finalizeRecordingAudio(id: id, format: activeRecordingFormat) }
            catch {
                errorMessage =
                    "Couldn’t convert the recording to \(activeRecordingFormat.rawValue.uppercased()). The original WAV audio is kept in this meeting. \(error.localizedDescription)"
                stopFailed = true
            }
        }
        if !stopFailed, liveTranscript.speakerEvidenceComplete, let saved = meeting(id: id) {
            let folder = directory(for: id)
            let files = audioURLs(for: saved)
            do {
                try await Task.detached(priority: .utility) {
                    try SpeakerEvidenceInputReceipt.seal(directory: folder, files: files)
                }.value
            }
            catch {
                errorMessage = "Couldn’t prepare speaker consolidation. Use Label Speakers to analyze saved audio."
            }
        }
        let finalizedLive = liveTranscript.draft.flatMap { $0.meetingID == id ? $0 : nil }
        let adoptedLive: Bool
        if let finalizedLive {
            adoptedLive = await adoptLiveTranscript(finalizedLive)
        }
        else {
            adoptedLive = false
        }
        recordingID = nil
        recordingStartedAt = nil
        recordingMeter.reset()
        captureTransition = false
        isFinalizingRecording = false
        localSearch.deferredRecordingChanges = false
        scheduleSearchIndexing()
        resumeSearchIndexingAfterRecording()
        if voiceLibrary.isLoaded, !isPreparingToQuit, !isChangingLibrary {
            voicePreparation.resumeAfterRecording(directory: directory(for:))
        }
        if adoptedLive { scheduleAutomaticSummary(id: id) }
        // A separate task, so callers awaiting the stop return once audio is saved.
        if !stopFailed && transcribeAfter
            && settings.shouldAutomaticallyTranscribe(
                hasUsableFinalizedLiveTranscript: finalizedLive?.hasUsableText == true)
        {
            Task { await transcribe(id: id) }
        }
        else if !stopFailed {
            await scheduleAutomaticSpeakerLabeling(id: id)
        }
    }
    func finalizeRecordingAudio(id: UUID, format: RecordingFormat) async throws {
        guard canSave, format != .wav else { return }
        guard await ensureMeetingLoaded(id: id) else {
            throw MeetingError.message("Couldn’t load the recording to finish its audio files.")
        }
        guard let meeting = self.meeting(id: id) else { return }
        let originals = audioURLs(for: meeting)
        guard !originals.isEmpty, originals.count == meeting.audioFiles.count else {
            throw MeetingError.message("A recorded audio file is missing.")
        }
        if originals.allSatisfy({ $0.pathExtension.lowercased() == format.rawValue }) { return }
        guard originals.allSatisfy({ $0.pathExtension.lowercased() == "wav" }) else {
            throw MeetingError.message("Recording conversion requires WAV source tracks.")
        }
        var encoded: [URL] = []
        do {
            for source in originals {
                let destination = source.deletingPathExtension().appendingPathExtension(format.rawValue)
                try await RecordingEncoder.encode(source: source, destination: destination, format: format)
                encoded.append(destination)
            }
            guard let index = meetings.firstIndex(where: { $0.id == id }) else {
                throw MeetingError.message("The recording no longer exists.")
            }
            meetings[index].audioFiles = encoded.map(\.lastPathComponent)
            if var profile = meetings[index].recordingProfile {
                for i in profile.tracks.indices {
                    if let sourceIndex = originals.firstIndex(where: {
                        $0.lastPathComponent == profile.tracks[i].filename
                    }) {
                        profile.tracks[i].filename = encoded[sourceIndex].lastPathComponent
                    }
                }
                meetings[index].recordingProfile = profile
            }
            guard await save() else {
                throw MeetingError.message(errorMessage ?? "Could not save compressed recording metadata.")
            }
        }
        catch {
            for file in encoded { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        // Remove only this capture's PCM spools, after durable metadata points to
        // every finalized compressed track. Failed conversion leaves WAV recoverable.
        for file in originals { try? FileManager.default.removeItem(at: file) }
    }
    @discardableResult func finalizeForQuit() async -> Bool {
        isPreparingToQuit = true
        if voiceLibrary.isLoaded { await voicePreparation.shutdown() }
        retiredVoiceSearchMigration?.cancel()
        await retiredVoiceSearchMigration?.value
        await localSearch.shutdown()
        libraryCopyTask?.cancel()
        await libraryCopyTask?.value
        RecordingPermissions.cancelPendingStart()
        while captureTransition { try? await Task.sleep(nanoseconds: 100_000_000) }
        await stopRecording(transcribeAfter: false)
        guard await prepareManagedTasksForQuit() else {
            isPreparingToQuit = false
            errorMessage = managedTaskShutdownError ?? "Couldn’t save task progress before quitting. Try again."
            await recoverUnfinishedManagedTasks()
            return false
        }
        await flushVoiceAssignmentRefresh()
        let wasWritable = canSave
        canSave = false
        let saved = await flushCanonicalWrites()
        let notesSaved: Bool
        do {
            try await notesStorage.flushAll()
            notesSaved = true
        }
        catch {
            errorMessage = "Couldn’t save meeting notes before quitting. \(error.localizedDescription)"
            notesSaved = false
        }
        if !saved || !notesSaved {
            canSave = wasWritable && !canonicalRecoveryRequired
            isPreparingToQuit = false
            await recoverUnfinishedManagedTasks()
        }
        return notesSaved && saved
    }
    /// A list drop creates one meeting per file; a detail drop appends aligned
    /// tracks to one meeting. Commit metadata once, or remove all new copies.
    @discardableResult func importAudioFiles(_ urls: [URL], into target: UUID? = nil) async throws -> [UUID] {
        guard canSave else { throw MeetingError.message("The library is read-only because loading failed.") }
        guard !isStartingRecording, !isFinalizingRecording, recordingID == nil else {
            throw MeetingError.message("Stop the recording before importing audio.")
        }
        guard !isImportingAudio else {
            throw MeetingError.message("Wait for the current import to finish before importing more audio.")
        }
        guard !urls.isEmpty else { return [] }
        if let target {
            guard await ensureMeetingLoaded(id: target) else {
                throw MeetingError.message("Couldn’t load the meeting to import audio.")
            }
            guard let meeting = self.meeting(id: target) else {
                throw MeetingError.message("This meeting no longer exists.")
            }
            guard meeting.transcriptionAttempt == nil, !isJobRunning(.transcription, .meeting(target)) else {
                throw MeetingError.message(
                    "Resume and finish this meeting’s pending transcription before adding tracks.")
            }
            guard !isJobRunning(.archive, .meeting(target)) else {
                throw MeetingError.message("Wait for this meeting’s archive to finish before adding tracks.")
            }
        }
        let scope: BackgroundJob.Scope = target.map { .meeting($0) } ?? .library
        guard beginJob(.importAudio, scope, progress: "Importing audio…") else { return [] }
        defer { endJob(.importAudio, scope) }
        var copied: [URL] = []
        var importMarkers: [URL] = []
        defer { for marker in importMarkers { try? FileManager.default.removeItem(at: marker) } }
        var newFolders: [URL] = []
        var additions: [(id: UUID, title: String, file: String, duration: Double, createdAt: Date)] = []
        do {
            for source in urls {
                try Task.checkCancellation()
                let ext = source.pathExtension.lowercased()
                guard source.isFileURL,
                    ["opus", "ogg", "wav", "m4a", "mp3", "mp4", "aiff", "aif", "caf", "flac", "aac", "mov"].contains(
                        ext)
                else {
                    throw MeetingError.message("Choose a supported audio or video file: \(source.lastPathComponent).")
                }
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw MeetingError.message("Choose a file, not a folder: \(source.lastPathComponent).")
                }
                let id = target ?? MeetingIdentity.newID()
                let createdAt = Date()
                let folder =
                    target != nil
                    ? directory(for: id)
                    : try MeetingFolderLocation.newFolder(id: id, date: createdAt, directory: dataDirectory)
                if !FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    newFolders.append(folder)
                }
                let marker = folder.appendingPathComponent(".app-import")
                if !importMarkers.contains(marker) {
                    try Data().write(to: marker, options: .atomic)
                    importMarkers.append(marker)
                }
                let base = source.deletingPathExtension().lastPathComponent
                let filenameBase = base.replacingOccurrences(of: "..", with: "_")
                var destination = folder.appendingPathComponent(filenameBase).appendingPathExtension(ext)
                var suffix = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = folder.appendingPathComponent("\(filenameBase)-\(suffix)").appendingPathExtension(ext)
                    suffix += 1
                }
                let copyTo = destination
                copied.append(destination)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: source, to: copyTo)
                }.value
                let duration: Double
                if ["opus", "ogg"].contains(ext) {
                    duration = try await AudioPlaybackPreparation.opusMetadata(destination).duration
                }
                else {
                    let asset = AVURLAsset(url: destination)
                    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                        throw MeetingError.message("No audio track found in \(source.lastPathComponent).")
                    }
                    duration = try await asset.load(.duration).seconds
                }
                guard duration.isFinite, duration > 0 else {
                    throw MeetingError.message("No playable audio in \(source.lastPathComponent).")
                }
                additions.append((id, base, destination.lastPathComponent, duration, createdAt))
            }
            try Task.checkCancellation()
            if let target {
                guard let index = meetings.firstIndex(where: { $0.id == target }) else {
                    throw MeetingError.message("This meeting was deleted during import.")
                }
                meetings[index].audioFiles += additions.map(\.file)
                meetings[index].duration = max(meetings[index].duration, additions.map(\.duration).max() ?? 0)
            }
            else {
                let imported = additions.map {
                    Meeting(
                        id: $0.id, title: $0.title, language: settings.defaultLanguage, createdAt: $0.createdAt,
                        duration: $0.duration,
                        audioFiles: [$0.file])
                }
                meetings.insert(contentsOf: imported, at: 0)
            }
            guard await save() else { throw MeetingError.message(errorMessage ?? "Could not save imported audio.") }
        }
        catch {
            for file in copied { try? FileManager.default.removeItem(at: file) }
            for folder in newFolders {
                if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            throw error
        }
        return target.map { [$0] } ?? additions.map(\.id)
    }
    func importArchive(url: URL) async throws {
        guard canSave else { throw MeetingError.message("The library is read-only because loading failed.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let archiveData = try Data(contentsOf: url)
        var meeting = try JSONDecoder().decode(Meeting.self, from: archiveData)
        meeting.id = MeetingIdentity.newID()
        meeting.audioFiles = []
        meeting.personIDs = []
        meeting.tagIDs = []
        meeting.transcriptionAttempt = nil
        for index in meeting.speakers.indices {
            meeting.speakers[index].personID = nil
            meeting.speakers[index].confidence = nil
            meeting.speakers[index].confirmed = false
            meeting.speakers[index].embedding = nil
            meeting.speakers[index].voiceEmbedding = nil
            meeting.speakers[index].voiceScope = nil
            meeting.speakers[index].voiceSampleRange = nil
            meeting.speakers[index].voiceSampleRevision = nil
            meeting.speakers[index].manuallyAssigned = nil
            meeting.speakers[index].voiceReviewOrigin = nil
            meeting.speakers[index].voiceReviewExampleID = nil
        }
        meeting.restoreSpeakerIdentities()
        let importedDirectory = try MeetingFolderLocation.newFolder(
            id: meeting.id, date: meeting.createdAt, directory: dataDirectory)
        do {
            // The location cache can evict a reservation while this import awaits an earlier save.
            // Establish the dated folder before notes persistence resolves its path independently.
            try FileManager.default.createDirectory(
                at: importedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try MeetingExport.importAssets(
                from: archiveData, source: url, notes: meeting.notes, directory: importedDirectory)
            meeting.notes = try NotesImageStore.canonicalizedNotes(in: meeting.notes, directory: importedDirectory)
        }
        catch {
            try? FileManager.default.removeItem(at: importedDirectory)
            throw error
        }
        meetings.insert(meeting, at: 0)
        guard await save() else {
            meetings.removeAll { $0.id == meeting.id }
            try? FileManager.default.removeItem(at: importedDirectory)
            throw MeetingError.message(errorMessage ?? "Could not save imported meeting.")
        }
        if !NotesAssets.tokens(in: meeting.notes + "\n" + meeting.summary).isEmpty,
            (try JSONSerialization.jsonObject(with: archiveData) as? [String: Any])?["notesAssets"] == nil
        {
            errorMessage =
                "Meeting text was imported. Its JSON file did not include an image manifest, so images linked from Notes or Summary were not imported."
        }
    }
}
extension MeetingStore {
    func invalidatePendingLiveVoiceEnrollment(meetingID: UUID, speakerID: UUID) {
        voiceEnrollmentRequests.removeValue(forKey: VoiceEnrollmentKey(meetingID: meetingID, speakerID: speakerID))
    }

    /// Only an explicit live assignment enrolls a clean, typed voice sample.
    /// Refresh this speaker's contribution without removing other model types.
    func enrollLiveVoice(meetingID: UUID, personID: UUID?, speakerID: UUID, embedding: TypedVoiceEmbedding?) async {
        guard libraryWritable, recordingID == meetingID,
            personID == nil || people.contains(where: { $0.id == personID })
        else { return }
        let key = VoiceEnrollmentKey(meetingID: meetingID, speakerID: speakerID)
        let request = UUID()
        voiceEnrollmentRequests[key] = request
        defer {
            if voiceEnrollmentRequests[key] == request { voiceEnrollmentRequests.removeValue(forKey: key) }
        }
        guard await voiceLibrary.awaitReady() else {
            errorMessage = voiceLibrary.errorMessage
            return
        }
        guard !Task.isCancelled, voiceEnrollmentRequests[key] == request else { return }
        _ = await enqueueCanonical { [self] in
            guard !Task.isCancelled, libraryWritable, voiceEnrollmentRequests[key] == request,
                meeting(id: meetingID) != nil,
                personID == nil || people.contains(where: { $0.id == personID })
            else { return true }
            guard voiceLibrary.assign(meetingID: meetingID, speakerID: speakerID, personID: personID, staged: true)
            else {
                errorMessage = voiceLibrary.errorMessage
                return false
            }
            for personIndex in people.indices {
                let isAssignedPerson = people[personIndex].id == personID
                people[personIndex].voiceSamples.removeAll {
                    guard $0.meetingID == meetingID && $0.speakerID == speakerID else { return false }
                    return !isAssignedPerson
                        || (embedding != nil && $0.voiceEmbedding?.type == embedding?.type)
                }
            }
            if let personID, let embedding, embedding.isValid,
                let index = people.firstIndex(where: { $0.id == personID })
            {
                people[index].voiceSamples.append(
                    .init(meetingID: meetingID, speakerID: speakerID, voiceEmbedding: embedding))
            }
            return await performCanonicalSave()
        }
    }

    func recordVoiceExample(meetingID: UUID, sample: LiveSpeakerAudioSample, embedding: TypedVoiceEmbedding) async {
        guard await voiceLibrary.awaitReady() else { return }
        guard !Task.isCancelled, libraryWritable, recordingID == meetingID,
            let meeting = meeting(id: meetingID)
        else { return }
        guard
            voiceLibrary.examples.filter({
                $0.meetingID == meetingID && $0.speakerID == sample.speakerID && $0.isPlayable
            }).count < 3
        else { return }
        let candidates = meeting.audioFiles.filter {
            LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == sample.source.rawValue
        }
        guard candidates.count == 1 else { return }
        // Capture evidence before matching. Profile reads and rejection checks run
        // together on the worker; a stale result cannot discard this sample.
        guard
            voiceLibrary.recordSample(
                meetingID: meetingID, speakerID: sample.speakerID,
                range: .init(
                    audioFile: candidates[0], source: sample.source.rawValue,
                    start: sample.start, end: sample.end),
                embedding: embedding, suggestion: nil)
        else {
            errorMessage = voiceLibrary.errorMessage
            return
        }
        await voiceLibrary.suggestReviewedPeople(from: people)
    }

    func refreshVoiceAssignments(meetingIDs: Set<UUID>) async {
        guard await voiceLibrary.awaitReady() else { return }
        for id in meetingIDs where id != recordingID {
            guard await ensureMeetingLoaded(id: id) else { continue }
            guard let meeting = meeting(id: id) else { continue }
            let updated = voiceLibrary.applyingDecisions(to: meeting)
            if updated != meeting { _ = await updateMeeting(updated) }
        }
        await voiceLibrary.suggestReviewedPeople(from: people)
    }

    private func scheduleVoiceAssignmentRefresh(meetingIDs: Set<UUID>) {
        let previous = voiceAssignmentRefresh
        voiceAssignmentRefreshRevision = UUID()
        voiceAssignmentRefreshCount += 1
        voiceAssignmentRefresh = Task { [weak self] in
            await previous?.value
            await self?.refreshVoiceAssignments(meetingIDs: meetingIDs)
            self?.voiceAssignmentRefreshCount -= 1
        }
    }

    func flushVoiceAssignmentRefresh() async {
        var revision: UUID
        repeat {
            revision = voiceAssignmentRefreshRevision
            await voiceAssignmentRefresh?.value
        } while revision != voiceAssignmentRefreshRevision
    }
}
