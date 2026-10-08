import Foundation

enum MeetingLoadResult { case loaded, superseded, failed }

/// Cancellation is recorded synchronously, before a completed read can publish on the main actor.
final class MeetingLoadConsumer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isActive: Bool { lock.withLock { !cancelled } }
}

@MainActor final class MeetingLoadOperation {
    let id = UUID()
    var consumers: [MeetingLoadConsumer] = []
    var task: Task<MeetingLoadResult, Never>!
    var isNeeded: Bool { consumers.contains { $0.isActive } }
}

/// One physical read at a time. Cancelled queued demand releases its continuation
/// immediately; a synchronous read already underway keeps its slot until it exits.
@MainActor final class MeetingLoadQueue {
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    var pendingCount: Int { waiters.count }

    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                if !occupied {
                    occupied = true
                    continuation.resume(returning: true)
                }
                else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.0 == id }) else { return }
                self.waiters.remove(at: index).1.resume(returning: false)
            }
        }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        }
        else {
            waiters.removeFirst().1.resume(returning: true)
        }
    }
}

/// Small catalog records are safe to keep in memory; content stays in each meeting folder.
struct MeetingListEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var summary: String
    var personIDs: [UUID]
    var tagIDs: [UUID]
    var audioFiles: [String]
    var hasTranscriptionAttempt: Bool
    var pendingProviderID: UUID?
    var pendingUploadProviderID: UUID?

    init(_ meeting: Meeting) {
        id = meeting.id
        title = meeting.title
        createdAt = meeting.createdAt
        duration = meeting.duration
        summary = String(meeting.summary.prefix(240))
        personIDs = Array(Set(meeting.personIDs + meeting.speakers.compactMap(\.personID))).sorted {
            $0.uuidString < $1.uuidString
        }
        tagIDs = meeting.tagIDs
        audioFiles = meeting.audioFiles
        hasTranscriptionAttempt = meeting.transcriptionAttempt != nil
        let pending = PrivacyContext.pending(in: [meeting]).first
        pendingProviderID = pending?.providerID
        pendingUploadProviderID = pending?.uploadProviderID
    }

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt > rhs.createdAt
    }
}

enum MeetingFolderStorage {
    static func folder(id: UUID, directory: URL, date: Date = Date()) -> URL {
        (try? MeetingFolderLocation.resolve(id: id, directory: directory, date: date))
            ?? MeetingFolderLocation.unavailable(id: id)
    }
    static func read(id: UUID, directory: URL) throws -> Meeting {
        let folder = try MeetingFolderLocation.resolve(id: id, directory: directory)
        let entry = try JSONDecoder().decode(
            MeetingListEntry.self, from: Data(contentsOf: folder.appendingPathComponent("metadata.json")))
        guard entry.id == id else { throw MeetingError.message("The meeting ID does not match its folder.") }
        let content = folder.appendingPathComponent("content.json")
        var meeting =
            FileManager.default.fileExists(atPath: content.path)
            ? try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: content)) : Meeting()
        meeting.id = entry.id
        meeting.title = entry.title
        meeting.createdAt = entry.createdAt
        meeting.duration = entry.duration
        meeting.audioFiles = entry.audioFiles
        meeting.personIDs = entry.personIDs
        meeting.tagIDs = entry.tagIDs
        if !meeting.transcript.isEmpty
            && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(TranscriptStorage.filename).path)
        {
            throw MeetingError.message("This transcript needs migration to transcript.jsonl before it can be opened.")
        }
        meeting.transcript = try TranscriptStorage.read(at: folder)
        for (name, key) in [("summary.md", \Meeting.summary), ("notes.md", \Meeting.notes)] {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                meeting[keyPath: key] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return meeting
    }
    static func write(_ meeting: Meeting, directory: URL, writeTranscript: Bool = true) throws {
        let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: directory, date: meeting.createdAt)
        MeetingFolderLocation.remember(folder, id: meeting.id, directory: directory)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var content = meeting
        content.transcript = []
        content.notes = ""
        content.summary = ""
        try encoder.encode(content).write(to: folder.appendingPathComponent("content.json"), options: .atomic)
        if writeTranscript { try TranscriptStorage.write(meeting.transcript, at: folder) }
        try Data(meeting.summary.utf8).write(to: folder.appendingPathComponent("summary.md"), options: .atomic)
        try encoder.encode(MeetingListEntry(meeting)).write(
            to: folder.appendingPathComponent("metadata.json"), options: .atomic)
    }
}

extension MeetingStore {
    static let meetingPageSize = 20
    var visibleMeetingEntries: [MeetingListEntry] { meetingCatalog }
    var hasMoreMeetings: Bool { meetingPageHasMore }
    func containsMeeting(id: UUID) -> Bool {
        meetings.contains { $0.id == id } || (try? libraryIndex?.entry(id: id)) != nil
            || FileManager.default.fileExists(
                atPath: MeetingFolderStorage.folder(id: id, directory: dataDirectory).appendingPathComponent(
                    "metadata.json"
                ).path)
    }
    var pendingMeetingTranscriptions: [PrivacyContext.PendingTranscription] {
        (try? libraryIndex?.pendingTranscriptions()) ?? []
    }
    @discardableResult func ensureMeetingLoaded(id: UUID) async -> Bool {
        let consumer = MeetingLoadConsumer()
        return await withTaskCancellationHandler {
            await loadMeeting(id: id, consumer: consumer)
        } onCancel: {
            consumer.cancel()
            Task { @MainActor [weak self] in
                guard let operation = self?.meetingLoadOperations[id], !operation.isNeeded else { return }
                operation.task.cancel()
            }
        }
    }

    private func loadMeeting(id: UUID, consumer: MeetingLoadConsumer) async -> Bool {
        defer { consumer.cancel() }
        let generation = externalReloadGeneration
        while !Task.isCancelled, generation == externalReloadGeneration,
            !deletingMeetingIDs.contains(id), !isChangingLibrary
        {
            if meetings.contains(where: { $0.id == id }) { return true }
            let task: Task<MeetingLoadResult, Never>
            if let operation = meetingLoadOperations[id], meetingLoadRequests[id] == operation.id, operation.isNeeded {
                operation.consumers.removeAll { !$0.isActive }
                operation.consumers.append(consumer)
                task = operation.task
            }
            else {
                if let obsolete = meetingLoadOperations[id], !obsolete.isNeeded { obsolete.task.cancel() }
                let operation = MeetingLoadOperation()
                operation.consumers.append(consumer)
                let request = operation.id
                meetingLoadRequests[id] = request
                let root = dataDirectory
                task = Task { @MainActor [weak self] in
                    guard let self else { return .failed }
                    defer {
                        if meetingLoadOperations[id]?.id == request { meetingLoadOperations.removeValue(forKey: id) }
                        if meetingLoadRequests[id] == request { meetingLoadRequests.removeValue(forKey: id) }
                    }
                    guard await meetingLoadQueue.acquire() else { return .superseded }
                    defer { meetingLoadQueue.release() }
                    guard operation.isNeeded, !Task.isCancelled else { return .superseded }
                    return await loadMeetingSnapshot(id: id, operation: operation, root: root, generation: generation)
                }
                operation.task = task
                meetingLoadOperations[id] = operation
            }
            switch await task.value {
            case .loaded: return !Task.isCancelled
            case .failed: return false
            case .superseded: continue
            }
        }
        return false
    }

    private func loadMeetingSnapshot(id: UUID, operation: MeetingLoadOperation, root: URL, generation: UUID) async
        -> MeetingLoadResult
    {
        let request = operation.id
        let reader = meetingLoadReader
        do {
            // A selected cold meeting must not observe a partially committed local transaction.
            _ = await flushCanonicalWrites()
            guard operation.isNeeded, meetingLoadRequests[id] == request, generation == externalReloadGeneration,
                !deletingMeetingIDs.contains(id), !isChangingLibrary
            else { return .superseded }
            let value = try await Task.detached(priority: .utility) {
                try reader(id, root)
            }.value
            guard operation.isNeeded, !Task.isCancelled, generation == externalReloadGeneration,
                meetingLoadRequests[id] == request,
                !deletingMeetingIDs.contains(id), !isChangingLibrary
            else { return .superseded }
            if meetings.contains(where: { $0.id == id }) { return .loaded }
            meetings.append(value)
            rememberLoadedMeeting(value)
            evictLoadedMeetings(keeping: id)
            if voiceLibrary.isLoaded { await recoverUnadoptedLiveTranscript(value) }
            guard generation == externalReloadGeneration, !deletingMeetingIDs.contains(id),
                let latest = meeting(id: id)
            else { return .failed }
            let resolved = voiceLibrary.applyingDecisions(to: latest)
            if resolved != latest, libraryWritable, recordingID != id {
                return await updateMeeting(resolved) ? .loaded : .failed
            }
            return .loaded
        }
        catch {
            guard operation.isNeeded, generation == externalReloadGeneration, meetingLoadRequests[id] == request,
                !deletingMeetingIDs.contains(id), !isChangingLibrary
            else { return .superseded }
            let failure = error as NSError
            CaptureLog.library.error(
                "Meeting load failed: domain=\(failure.domain, privacy: .public) code=\(failure.code) meeting=\(id.uuidString, privacy: .private)"
            )
            if let missing = error as? CocoaError,
                missing.code == .fileReadNoSuchFile || missing.code == .fileNoSuchFile,
                let monitor = libraryMonitor,
                beginJob(.libraryIndex, .meeting(id), progress: "Updating Index")
            {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { endJob(.libraryIndex, .meeting(id)) }
                    do {
                        let removed = try await monitor.reconcileMissingMeeting(id: id)
                        guard generation == externalReloadGeneration, !isChangingLibrary else { return }
                        if removed {
                            CaptureLog.library.notice("Removed an index record whose meeting metadata is missing.")
                            meetingPageError = nil
                            resetMeetingPages()
                        }
                        else {
                            meetingPageError = "Couldn’t load this meeting. \(error.localizedDescription)"
                        }
                    }
                    catch {
                        guard generation == externalReloadGeneration, !isChangingLibrary else { return }
                        let failure = error as NSError
                        CaptureLog.library.error(
                            "Index reconciliation failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)"
                        )
                        libraryDataStatus.error = "Couldn’t update the index. \(error.localizedDescription)"
                    }
                }
            }
            else {
                meetingPageError = "Couldn’t load this meeting. \(error.localizedDescription)"
            }
            return .failed
        }
    }
    func meeting(id: UUID) -> Meeting? { meetings.first { $0.id == id } }
    func resetMeetingPages(evictLoaded: Bool = false) {
        resetMeetingPrefetch()
        if evictLoaded { clearLoadedMeetingCache() }
        meetingCatalog = []
        visibleMeetingIDs = []
        meetingPageHasMore = true
        meetingPageHasPrevious = false
        loadNextMeetingPage()
    }
    func loadNextMeetingPage() {
        guard !isLoadingMeetingPage, meetingPageHasMore else { return }
        isLoadingMeetingPage = true
        defer { isLoadingMeetingPage = false }
        do {
            let next =
                try libraryIndex?.page(
                    after: meetingCatalog.last, limit: Self.meetingPageSize, query: meetingSearch,
                    excludingTagIDs: excludedTagIDs)
                ?? []
            meetingCatalog.append(contentsOf: next)
            if meetingCatalog.count > Self.meetingWindowLimit {
                meetingCatalog.removeFirst(meetingCatalog.count - Self.meetingWindowLimit)
                meetingPageHasPrevious = true
            }
            visibleMeetingIDs = meetingCatalog.map(\.id)
            meetingPageHasMore = next.count == Self.meetingPageSize
        }
        catch { meetingPageError = error.localizedDescription }
    }
    /// New initial-index batches may extend either end of a partially browsed catalog.
    /// Preserve the current rows and selection; re-enable only the relevant paging sentinels.
    func refreshMeetingPageAvailabilityAfterIndexCommit() {
        guard !isLoadingMeetingPage else { return }
        if meetingCatalog.isEmpty {
            guard let first = try? libraryIndex?.page(limit: 1, query: meetingSearch, excludingTagIDs: excludedTagIDs),
                !first.isEmpty
            else { return }
            resetMeetingPages()
            return
        }
        do {
            let more =
                !(try libraryIndex?.page(
                    after: meetingCatalog.last, limit: 1, query: meetingSearch, excludingTagIDs: excludedTagIDs) ?? [])
                .isEmpty
            let previous =
                !(try libraryIndex?.page(
                    before: meetingCatalog.first, limit: 1, query: meetingSearch, excludingTagIDs: excludedTagIDs) ?? [])
                .isEmpty
            if more != meetingPageHasMore {
                objectWillChange.send()
                meetingPageHasMore = more
            }
            if previous != meetingPageHasPrevious { meetingPageHasPrevious = previous }
        }
        catch { meetingPageError = error.localizedDescription }
    }

    func loadPreviousMeetingPage() {
        guard !isLoadingMeetingPage, meetingPageHasPrevious, let first = meetingCatalog.first else { return }
        isLoadingMeetingPage = true
        defer { isLoadingMeetingPage = false }
        do {
            let previous =
                try libraryIndex?.page(
                    before: first, limit: Self.meetingPageSize, query: meetingSearch, excludingTagIDs: excludedTagIDs)
                ?? []
            meetingCatalog.insert(contentsOf: previous, at: 0)
            if meetingCatalog.count > Self.meetingWindowLimit {
                meetingCatalog.removeLast(meetingCatalog.count - Self.meetingWindowLimit)
                meetingPageHasMore = true
            }
            visibleMeetingIDs = meetingCatalog.map(\.id)
            meetingPageHasPrevious = previous.count == Self.meetingPageSize
        }
        catch { meetingPageError = error.localizedDescription }
    }
    func searchMeetingPages(_ query: String) async {
        meetingSearch = query
        resetMeetingPages()
    }
    func refreshMeetingPagesAfterSave(previousIDs: Set<UUID>, quiet: Bool = false) async {
        let viewport = meetingPrefetch.viewport
        if !quiet { resetMeetingPrefetch() }
        let pageGeneration = meetingPrefetch.generation
        if !quiet { isLoadingMeetingPage = true }
        defer {
            if !quiet, pageGeneration == meetingPrefetch.generation {
                isLoadingMeetingPage = false
                // Refresh may leave the viewport unchanged, so no scroll callback
                // is guaranteed to arrive to restart interrupted read-ahead.
                if !Task.isCancelled, let latest = meetingPrefetch.viewport ?? viewport { prefetchMeetings(latest) }
            }
        }
        let generation = meetingSearchGeneration
        let rootGeneration = externalReloadGeneration
        let originalIDs = visibleMeetingIDs
        let index = libraryIndex
        let count = max(Self.meetingPageSize, meetingCatalog.count)
        let first = meetingPageHasPrevious ? meetingCatalog.first : nil
        let query = meetingSearch
        let excluded = excludedTagIDs
        do {
            let entries = try await Task.detached(priority: .utility) {
                if let first {
                    let following =
                        try index?.page(after: first, limit: count, query: query, excludingTagIDs: excluded) ?? []
                    let updated = try index?.entry(id: first.id)
                    return Array(
                        (updated.flatMap { excluded.isDisjoint(with: $0.tagIDs) ? [$0] + following : nil } ?? following)
                            .prefix(count))
                }
                return try index?.page(limit: count, query: query, excludingTagIDs: excluded) ?? []
            }.value
            guard !Task.isCancelled, pageGeneration == meetingPrefetch.generation,
                generation == meetingSearchGeneration, rootGeneration == externalReloadGeneration,
                originalIDs == visibleMeetingIDs, query == meetingSearch, excluded == excludedTagIDs
            else { return }
            if meetingCatalog != entries {
                if quiet { resetMeetingPrefetch() }
                meetingCatalog = entries
                if quiet, let latest = viewport { prefetchMeetings(latest) }
            }
            let ids = entries.map(\.id)
            if visibleMeetingIDs != ids { visibleMeetingIDs = ids }
            let more = entries.count == count
            if !quiet, meetingPageHasMore != more { meetingPageHasMore = more }
        }
        catch {
            if !Task.isCancelled, pageGeneration == meetingPrefetch.generation,
                generation == meetingSearchGeneration, rootGeneration == externalReloadGeneration
            {
                if meetingPageError != error.localizedDescription { meetingPageError = error.localizedDescription }
            }
        }
    }
}
