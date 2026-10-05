import AVFoundation
import Combine
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published var contextualChats: [String: [ChatMessage]] = [:]
    @Published var meetings: [Meeting] = []
    @Published var meetingCatalog: [MeetingListEntry] = []
    @Published var visibleMeetingIDs: [UUID] = []
    @Published var latestCreatedMeetingID: UUID?
    @Published var isLoadingMeetingPage = false
    @Published var isSearchingMeetings = false
    @Published var meetingPageError: String?
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
    private var pendingExternalChanges: ExternalLibraryChanges = []
    private var externalReloadTask: Task<Void, Never>?
    var meetingSearch = ""
    var meetingSearchGeneration = UUID()
    @Published var people: [Person] = []
    @Published var tags: [MeetingTag] = []
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
    @Published var managedTasks: [ManagedTaskRecord] = []
    @Published var managedTaskRevision = 0
    @Published var managedTasksLoading = false
    @Published var managedTaskStateCounts: [ManagedTaskState: Int] = [:]
    @Published var managedTaskJournalError: String?
    lazy var managedTaskJournal = ManagedTaskJournal(
        url: dataDirectory.appendingPathComponent("tasks.jsonl"),
        indexURL: indexDirectory.appendingPathComponent("index.db"))
    private var managedTaskWakeObserver: ManagedTaskWakeObserver?
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
    lazy var voiceSearch: VoiceSearchController = {
        let controller = VoiceSearchController(directory: dataDirectory, indexDirectory: indexDirectory)
        voiceSearchJobObservation = controller.$isBuilding.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return controller
    }()
    private var voiceSearchJobObservation: AnyCancellable?
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
        !LocalModelManager.shared.isBusy && !voiceSearch.isBuilding && !isChangingLibrary
            && recordingID == nil && !isStartingRecording
            && !isFinalizingRecording
            && !captureTransition && backgroundJobs.isEmpty && managedTaskOperations.isEmpty
            && !managedTasksLoading
            && managedTaskStateCounts[.queued, default: 0] + managedTaskStateCounts[.running, default: 0] == 0
            && !managedTasks.contains(where: { $0.state.isActive })
    }
    lazy var notesStorage = NotesStorage(directory: dataDirectory)
    lazy var voiceLibrary: VoiceLibraryStore = {
        let library = VoiceLibraryStore(
            directory: dataDirectory,
            canWrite: { [weak self] in self?.libraryWritable == true })
        library.didChange = { [weak self] ids in self?.refreshVoiceAssignments(meetingIDs: ids) }
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
    lazy var voicePreparation = VoiceLibraryPreparation(
        library: voiceLibrary, people: { [weak self] in self?.people ?? [] })
    private var recorder: AudioCapture?
    private var captureTransition = false
    private var activeRecordingFormat: RecordingFormat = .opus
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
        recordingID == nil && !isStartingRecording && !isFinalizingRecording && !captureTransition && canSave
    }

    init(dataDirectory: URL? = nil) {
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
                meetings[index].notes = try notesStorage.load(meetings[index].id, fallback: meetings[index].notes)
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
            recoverUnadoptedLiveTranscripts()
            refreshArchiveStatuses()
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
            _ = voicePreparation
            if FileManager.default.fileExists(atPath: self.dataDirectory.appendingPathComponent("tasks.jsonl").path) {
                managedTasksLoading = true
                Task { [weak self] in await self?.prepareManagedTasks() }
            }
            else {
                do { try restoreManagedTasks() }
                catch { managedTaskJournalError = "Couldn’t load saved tasks. \(error.localizedDescription)" }
            }
            managedTaskWakeObserver = ManagedTaskWakeObserver { [weak self] in
                self?.recoverUnfinishedManagedTasks()
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
            try LocalModelManager.shared.suspendForLibraryChange()
            try notesStorage.flushAll()
            writableBeforeFolderChange = canSave
            previousFolderPreference = folderPreferences.data
            canSave = false
            isCopyingLibrary = true
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
            canSave = writableBeforeFolderChange
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
        canSave = writableBeforeFolderChange
        if canSave { startLibraryMonitoring() }
    }

    @discardableResult private func save(personMerge: PersonMerge? = nil) -> Bool {
        guard canSave else {
            errorMessage = "Library is read-only because loading failed. Check the data folder before saving changes."
            return false
        }
        for index in meetings.indices {
            let previous = lastSavedLibrary.meetings.first { $0.id == meetings[index].id }
            if previous != meetings[index] {
                meetings[index] = MeetingSpeakerColors.assigning(meetings[index], previous: previous)
            }
        }
        var transaction = LibraryFileTransaction(root: dataDirectory)
        var mergedEntries: [MeetingListEntry] = []
        do {
            try voiceLibrary.writePending(transaction: &transaction)
            let changed = meetings.filter { meeting in
                lastSavedLibrary.meetings.first(where: { $0.id == meeting.id }) != meeting
            }
            for meeting in changed {
                _ = try MeetingFolderLocation.resolve(id: meeting.id, directory: dataDirectory, date: meeting.createdAt)
            }
            let dataEventBaselines = Dictionary(
                uniqueKeysWithValues: changed.map { meeting in
                    (meeting.id, DataEventJournal.documentSnapshot(directory: directory(for: meeting.id)))
                })
            try notesStorage.flushAll()
            for meeting in changed where notesStorage.saved[meeting.id] != meeting.notes {
                try notesStorage.write(meeting.id, text: meeting.notes)
            }
            for meeting in changed {
                if let baseline = lastSavedLibrary.meetings.first(where: { $0.id == meeting.id }) {
                    var disk = try MeetingFolderStorage.read(id: meeting.id, directory: dataDirectory)
                    // NotesStorage independently arbitrates Markdown edits and conflict copies.
                    disk.notes = baseline.notes
                    // The recording writer owns canonical rows until Stop has
                    // published its final metadata. Unrelated saves cannot replace them.
                    if recordingID == meeting.id { disk.transcript = baseline.transcript }
                    var proposed = meeting
                    proposed.notes = baseline.notes
                    var normalizedBaseline = baseline
                    normalizedBaseline.personIDs = MeetingListEntry(baseline).personIDs
                    proposed.personIDs = MeetingListEntry(proposed).personIDs
                    disk.personIDs = MeetingListEntry(disk).personIDs
                    guard disk == normalizedBaseline || disk == proposed else {
                        throw MeetingError.message("This meeting changed on disk. Reload it before saving.")
                    }
                }
                let folder = directory(for: meeting.id)
                var names = ["metadata.json", "content.json", "summary.md"]
                let prior = lastSavedLibrary.meetings.first { $0.id == meeting.id }
                if recordingID != meeting.id && (prior == nil || prior?.transcript != meeting.transcript) {
                    names += [TranscriptStorage.filename, LiveTranscriptProjection.checkpointName]
                }
                for name in names {
                    try transaction.remember(folder.appendingPathComponent(name))
                }
            }
            for (kind, ids) in [
                (
                    "people",
                    Set(
                        people.filter { !lastSavedLibrary.people.contains($0) }.map(\.id)
                            + lastSavedLibrary.people.filter { !people.contains($0) }.map(\.id))
                ),
                (
                    "tags",
                    Set(
                        tags.filter { !lastSavedLibrary.tags.contains($0) }.map(\.id)
                            + lastSavedLibrary.tags.filter { !tags.contains($0) }.map(\.id))
                ),
            ] {
                for id in ids {
                    try transaction.remember(
                        dataDirectory.appendingPathComponent(kind).appendingPathComponent(id.uuidString + ".json"))
                }
            }
            if contextualChats != lastSavedLibrary.contextualChats {
                try transaction.remember(dataDirectory.appendingPathComponent("context-chats.json"))
            }
            try notesStorage.flushAll()
            for meeting in meetings where lastSavedLibrary.meetings.first(where: { $0.id == meeting.id }) != meeting {
                if notesStorage.saved[meeting.id] != meeting.notes {
                    try notesStorage.write(meeting.id, text: meeting.notes)
                }
                let prior = lastSavedLibrary.meetings.first { $0.id == meeting.id }
                let writeTranscript =
                    recordingID != meeting.id && (prior == nil || prior?.transcript != meeting.transcript)
                try MeetingFolderStorage.write(meeting, directory: dataDirectory, writeTranscript: writeTranscript)

            }
            try FileEntityStorage.save(
                people, previous: lastSavedLibrary.people, kind: "people", directory: dataDirectory)
            try FileEntityStorage.save(tags, previous: lastSavedLibrary.tags, kind: "tags", directory: dataDirectory)
            if contextualChats != lastSavedLibrary.contextualChats {
                try JSONEncoder().encode(contextualChats).write(
                    to: dataDirectory.appendingPathComponent("context-chats.json"), options: .atomic)
            }
            if let personMerge, let libraryIndex {
                var cursor: MeetingListEntry?
                let loadedIDs = Set(meetings.map(\.id))
                while true {
                    let page = try libraryIndex.page(after: cursor, limit: 20)
                    guard !page.isEmpty else { break }
                    for entry in page where !loadedIDs.contains(entry.id) {
                        if let updated = try personMerge.rewriteStoredMeeting(
                            id: entry.id, directory: dataDirectory, transaction: &transaction)
                        {
                            mergedEntries.append(updated)
                        }
                    }
                    cursor = page.last
                }
            }
            try transaction.commit()
            voiceLibrary.completePending(committed: true)
            for entry in mergedEntries {
                do {
                    let folder = directory(for: entry.id)
                    for name in ["metadata.json", "content.json"]
                    where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                        try DataEventJournal.fileSaved(
                            folder.appendingPathComponent(name), action: .modified, directory: folder)
                    }
                }
                catch {
                    errorMessage =
                        "People were merged, but their data events couldn’t be saved. \(error.localizedDescription)"
                }
            }
            for meeting in changed {
                do {
                    let folder = directory(for: meeting.id)
                    try DataEventJournal.recordDocuments(
                        directory: folder, previous: dataEventBaselines[meeting.id] ?? [:])
                    let previousAudio = lastSavedLibrary.meetings.first { $0.id == meeting.id }?.audioFiles ?? []
                    for name in meeting.audioFiles where !previousAudio.contains(name) {
                        try DataEventJournal.fileSaved(
                            folder.appendingPathComponent(name), action: .created, directory: folder)
                    }
                }
                catch {
                    errorMessage =
                        "Files were saved, but their data events couldn’t be saved. \(error.localizedDescription)"
                }
            }
            do {
                if !libraryDataStatus.isBuilding {
                    for meeting in changed { try libraryIndex?.upsert(MeetingListEntry(meeting), refreshSearch: false) }
                    for entry in mergedEntries { try libraryIndex?.upsert(entry, refreshSearch: false) }
                    if !changed.isEmpty || !mergedEntries.isEmpty { meetingIndexRevision = UUID() }
                    let paths = (changed.map(\.id) + mergedEntries.map(\.id)).map {
                        directory(for: $0).appendingPathComponent("metadata.json")
                    }
                    if !paths.isEmpty {
                        libraryMonitor?.process(.init(paths: paths, requiresScan: false, eventID: 0))
                    }
                }
            }
            catch { libraryDataStatus.error = "Couldn’t refresh the index. Rebuild it in Data settings." }
            let exclusionChanged = Set(lastSavedLibrary.tags.filter(\.isExcluded).map(\.id)) != excludedTagIDs
            refreshDirectoryIndex(previousPeople: lastSavedLibrary.people, previousTags: lastSavedLibrary.tags)
            lastSavedLibrary = LibrarySnapshot(
                contextualChats: contextualChats, meetings: meetings, people: people, tags: tags)
            if exclusionChanged {
                resetMeetingPages()
            }
            else {
                refreshMeetingPagesAfterSave(previousIDs: [])
            }
            return true
        }
        catch {
            try? transaction.restore()
            voiceLibrary.completePending(committed: false)
            meetings = lastSavedLibrary.meetings.map { old in
                var value = old
                value.notes = notesStorage.pending[old.id] ?? notesStorage.saved[old.id] ?? old.notes
                return value
            }
            people = lastSavedLibrary.people
            tags = lastSavedLibrary.tags
            contextualChats = lastSavedLibrary.contextualChats
            errorMessage = "Couldn’t save changes. \(error.localizedDescription)"
            return false
        }
    }
    func requestExternalLibraryReload(paths: [URL], rebuild: Bool) {
        pendingExternalChanges.formUnion(.init(paths: paths, root: dataDirectory, rebuild: rebuild))
        guard externalReloadTask == nil, !pendingExternalChanges.isEmpty else { return }
        externalReloadTask = Task { [weak self] in
            guard let self else { return }
            defer { externalReloadTask = nil }
            while !pendingExternalChanges.isEmpty {
                let changes = pendingExternalChanges
                pendingExternalChanges = []
                let root = dataDirectory
                let originalPeople = people
                let originalTags = tags
                do {
                    let snapshot: ExternalCatalogSnapshot?
                    do {
                        snapshot = try await Task.detached(priority: .utility) {
                            try ExternalCatalogSnapshot.read(changes: changes, directory: root)
                        }.value
                    }
                    catch {
                        // A malformed catalog must not block independent meeting
                        // and task refreshes in a root-level recovery batch.
                        libraryDataStatus.error = error.localizedDescription
                        snapshot = ExternalCatalogSnapshot(people: nil, tags: nil)
                    }
                    guard root == dataDirectory else { continue }
                    guard let snapshot,
                        !FileManager.default.fileExists(
                            atPath: root.appendingPathComponent(".document-transaction").path)
                    else {
                        pendingExternalChanges.formUnion(changes)
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    if let fresh = snapshot.people, people == originalPeople, lastSavedLibrary.people == originalPeople
                    {
                        if people != fresh { people = fresh }
                        lastSavedLibrary.people = fresh
                    }
                    let previousExcluded = excludedTagIDs
                    if let fresh = snapshot.tags, tags == originalTags, lastSavedLibrary.tags == originalTags {
                        if tags != fresh { tags = fresh }
                        lastSavedLibrary.tags = fresh
                    }
                    if previousExcluded != excludedTagIDs { resetMeetingPages() }
                    if changes.contains(.meetings) { reloadExternalLibraryDocuments(reloadCatalogs: false) }
                    if changes.contains(.tasks) { reloadExternalManagedTasks() }
                }
                catch { libraryDataStatus.error = error.localizedDescription }
            }
        }
    }

    func reloadExternalLibraryDocuments(reloadCatalogs: Bool = true) {
        // A file transaction may temporarily remove or replace a document. Its absence
        // becomes authoritative only after the transaction has committed.
        guard
            !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent(".document-transaction").path)
        else { return }
        do {
            var removed = Set<UUID>()
            defer {
                meetings.removeAll { removed.contains($0.id) }
                lastSavedLibrary.meetings.removeAll { removed.contains($0.id) }
                for id in removed {
                    notesStorage.saved.removeValue(forKey: id)
                    archiveStatuses.removeValue(forKey: id)
                }
            }
            for position in meetings.indices {
                let current = meetings[position]
                guard notesStorage.pending[current.id] == nil,
                    lastSavedLibrary.meetings.first(where: { $0.id == current.id }) == current,
                    !backgroundJobs.contains(where: { $0.meetingID == current.id }), recordingID != current.id
                else { continue }
                let metadata = directory(for: current.id).appendingPathComponent("metadata.json")
                do { _ = try metadata.resourceValues(forKeys: [.isRegularFileKey]) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    removed.insert(current.id)
                    continue
                }
                let fresh = try MeetingFolderStorage.read(id: current.id, directory: dataDirectory)
                if meetings[position] != fresh { meetings[position] = fresh }
                if let saved = lastSavedLibrary.meetings.firstIndex(where: { $0.id == current.id }) {
                    lastSavedLibrary.meetings[saved] = fresh
                }
            }
            if reloadCatalogs, people == lastSavedLibrary.people {
                people = try FileEntityStorage.load(Person.self, kind: "people", directory: dataDirectory)
                lastSavedLibrary.people = people
            }
            let previousExcluded = excludedTagIDs
            if reloadCatalogs, tags == lastSavedLibrary.tags {
                tags = try FileEntityStorage.load(MeetingTag.self, kind: "tags", directory: dataDirectory)
                lastSavedLibrary.tags = tags
            }
            if previousExcluded != excludedTagIDs {
                resetMeetingPages()
            }
            else {
                refreshMeetingPagesAfterSave(previousIDs: [])
            }
            refreshMeetingPageAvailabilityAfterIndexCommit()
        }
        catch { libraryDataStatus.error = error.localizedDescription }
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
        meetings = []
        lastSavedLibrary.meetings = []
    }
    func saveContextChat(key: String, messages: [ChatMessage]) {
        guard canSave else { return }
        contextualChats[key] = messages
        save()
    }
    @discardableResult func saveSettings() -> Bool {
        guard canSave else {
            errorMessage = "Restore the local library before changing settings."
            return false
        }
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
        return true
    }
    func insertImportedMeeting(_ meeting: Meeting) throws {
        guard canSave else { throw MeetingError.message("The library is read-only because loading failed.") }
        meetings.insert(meeting, at: 0)
        guard save() else { throw MeetingError.message(errorMessage ?? "Could not save imported meeting.") }
        latestCreatedMeetingID = meeting.id
    }
    @discardableResult func createMeeting(title: String = "Untitled Meeting", language: String? = nil) -> UUID {
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
        if save() { latestCreatedMeetingID = meeting.id }
        return meeting.id
    }
    @discardableResult func updateMeeting(_ meeting: Meeting) -> Bool {
        _ = ensureMeetingLoaded(id: meeting.id)
        guard canSave, let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return false }
        meetings[index] = meeting
        return save()
    }
    @discardableResult func deleteMeeting(id: UUID) -> Bool {
        guard canSave else { return false }
        guard !voiceSearch.isBuilding || voiceSearch.buildingMeetingID != id else {
            errorMessage = "Stop voice indexing before deleting this meeting."
            return false
        }
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
        do {
            try notesStorage.flush(id)
            let original = meetings
            let originalCatalog = meetingCatalog
            meetings.removeAll { $0.id == id }
            meetingCatalog.removeAll { $0.id == id }
            let folder = directory(for: id)
            do {
                if FileManager.default.fileExists(atPath: folder.path) {
                    _ = try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                }
                try libraryIndex?.remove(id: id)
                voiceSearch.invalidateDeletedMeeting(id)
                notesStorage.discard(id)
                return save()
            }
            catch {
                meetings = original
                meetingCatalog = originalCatalog
                save()
                throw error
            }
        }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    @discardableResult func addPerson(name: String) -> UUID {
        guard canSave else { return UUID() }
        let person = Person(name: name)
        people.append(person)
        save()
        return person.id
    }
    func updatePerson(_ person: Person) {
        guard canSave else { return }
        if let i = people.firstIndex(where: { $0.id == person.id }) {
            people[i] = person
            save()
        }
    }
    var canMergePeople: Bool {
        canSave && canChangeLibraryFolder && !libraryDataStatus.isBuilding && !indexNeedsInitialRebuild
            && libraryIndex != nil
    }

    @discardableResult
    func mergePerson(id: UUID, into targetID: UUID) -> Bool {
        mergePeople(ids: [id, targetID], into: targetID)
    }

    @discardableResult
    func mergePeople(ids: Set<UUID>, into targetID: UUID) -> Bool {
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
        return save(personMerge: merge)
    }

    func deletePerson(id: UUID) {
        guard canSave, removeRelationships(personID: id) else { return }
        guard voiceLibrary.removePerson(id: id, staged: true) else {
            errorMessage = voiceLibrary.errorMessage
            return
        }
        people.removeAll { $0.id == id }
        contextualChats.removeValue(forKey: Self.contextChatKey(personID: id))
        save()
    }
    private func removeRelationships(personID: UUID? = nil, tagID: UUID? = nil) -> Bool {
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
                    guard ensureMeetingLoaded(id: entry.id),
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
                guard save() else { return false }
                cursor = page.last
            }
        }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    @discardableResult func addTag(name: String, color: String = "blue") -> UUID {
        guard canSave else { return UUID() }
        let tag = MeetingTag(name: name, color: color)
        tags.append(tag)
        save()
        return tag.id
    }
    var excludedTagIDs: Set<UUID> { Set(tags.filter(\.isExcluded).map(\.id)) }
    var listedPeople: [Person] {
        let excluded = excludedTagIDs
        return people.filter { excluded.isDisjoint(with: $0.tagIDs) }
    }
    func updateTag(_ tag: MeetingTag) {
        guard canSave else { return }
        if let i = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[i] = tag
            save()
        }
    }
    func deleteTag(id: UUID) {
        guard canSave, removeRelationships(tagID: id) else { return }
        tags.removeAll { $0.id == id }
        for index in people.indices { people[index].tagIDs.removeAll { $0 == id } }
        contextualChats.removeValue(forKey: Self.contextChatKey(tagID: id))
        save()
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
        // Stop the existing build before a new, growing recording can enter
        // a later page of its saved-library scan.
        voiceSearch.cancel()
        let microphone = microphoneEnabled ?? settings.captureMicrophone
        let systemAudio = systemEnabled ?? settings.captureSystemAudio
        isStartingRecording = true
        defer { isStartingRecording = false }
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
            guard save() else {
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
                speakerRecognitionEnabled: settings.recognizeLiveSpeakers
                    && settings.serviceProviders.contains {
                        $0.id == settings.speakerRecognitionProviderID && $0.supports(.speakerRecognition)
                    },
                people: { [weak self] in self?.people ?? [] },
                enrollVoice: { [weak self] personID, speakerID, embedding in
                    self?.enrollLiveVoice(
                        meetingID: meeting.id, personID: personID,
                        speakerID: speakerID, embedding: embedding)
                },
                recordVoice: { [weak self] sample, embedding in
                    self?.recordVoiceExample(meetingID: meeting.id, sample: sample, embedding: embedding)
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
        _ = flushNotes()
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
            if !save() { stopFailed = true }
        }
        if !stopFailed && activeRecordingFormat == .m4a {
            do { try await finalizeRecordingAudio(id: id, format: activeRecordingFormat) }
            catch {
                errorMessage =
                    "Couldn’t convert the recording to \(activeRecordingFormat.rawValue.uppercased()). The original WAV audio is kept in this meeting. \(error.localizedDescription)"
                stopFailed = true
            }
        }
        let finalizedLive = liveTranscript.draft.flatMap { $0.meetingID == id ? $0 : nil }
        let adoptedLive = finalizedLive.map { adoptLiveTranscript($0) } ?? false
        recordingID = nil
        recordingStartedAt = nil
        recordingMeter.reset()
        captureTransition = false
        isFinalizingRecording = false
        if adoptedLive { scheduleAutomaticSummary(id: id) }
        // A separate task, so callers awaiting the stop return once audio is saved.
        if !stopFailed && transcribeAfter
            && settings.shouldAutomaticallyTranscribe(
                hasUsableFinalizedLiveTranscript: finalizedLive?.hasUsableText == true)
        {
            Task { await transcribe(id: id) }
        }
        else if !stopFailed {
            scheduleAutomaticSpeakerLabeling(id: id)
        }
    }
    func finalizeRecordingAudio(id: UUID, format: RecordingFormat) async throws {
        guard canSave, format != .wav else { return }
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
            guard save() else {
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
        await voiceSearch.shutdown()
        libraryCopyTask?.cancel()
        await libraryCopyTask?.value
        RecordingPermissions.cancelPendingStart()
        while captureTransition { try? await Task.sleep(nanoseconds: 100_000_000) }
        await stopRecording(transcribeAfter: false)
        return flushNotes()
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
            guard save() else { throw MeetingError.message(errorMessage ?? "Could not save imported audio.") }
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
    func importArchive(url: URL) throws {
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
            try MeetingExport.importAssets(
                from: archiveData, source: url, notes: meeting.notes, directory: importedDirectory)
            meeting.notes = try NotesImageStore.canonicalizedNotes(in: meeting.notes, directory: importedDirectory)
        }
        catch {
            try? FileManager.default.removeItem(at: importedDirectory)
            throw error
        }
        meetings.insert(meeting, at: 0)
        guard save() else {
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
    /// Only an explicit live assignment enrolls a clean, typed voice sample.
    /// Refresh this speaker's contribution without removing other model types.
    func enrollLiveVoice(meetingID: UUID, personID: UUID?, speakerID: UUID, embedding: TypedVoiceEmbedding?) {
        guard libraryWritable, recordingID == meetingID,
            personID == nil || people.contains(where: { $0.id == personID })
        else { return }
        guard voiceLibrary.assign(meetingID: meetingID, speakerID: speakerID, personID: personID, staged: true) else {
            errorMessage = voiceLibrary.errorMessage
            return
        }
        let previous = people
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
        if !save() { people = previous }
    }

    func recordVoiceExample(meetingID: UUID, sample: LiveSpeakerAudioSample, embedding: TypedVoiceEmbedding) {
        guard libraryWritable, let meeting = meeting(id: meetingID) else { return }
        guard
            voiceLibrary.examples.filter({
                $0.meetingID == meetingID && $0.speakerID == sample.speakerID && $0.isPlayable
            }).count < 3
        else { return }
        let candidates = meeting.audioFiles.filter {
            LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == sample.source.rawValue
        }
        guard candidates.count == 1 else { return }
        let match = SpeakerRecognition.match(embedding: embedding, people: voiceLibrary.matchingPeople(from: people))
        if !voiceLibrary.recordSample(
            meetingID: meetingID, speakerID: sample.speakerID,
            range: .init(
                audioFile: candidates[0], source: sample.source.rawValue,
                start: sample.start, end: sample.end),
            embedding: embedding, suggestion: match?.personID)
        {
            errorMessage = voiceLibrary.errorMessage
        }
    }

    func refreshVoiceAssignments(meetingIDs: Set<UUID>) {
        for id in meetingIDs where id != recordingID {
            guard let meeting = meeting(id: id) else { continue }
            let updated = voiceLibrary.applyingDecisions(to: meeting)
            if updated != meeting { _ = updateMeeting(updated) }
        }
        voiceLibrary.suggestReviewedPeople(from: people)
    }
}
