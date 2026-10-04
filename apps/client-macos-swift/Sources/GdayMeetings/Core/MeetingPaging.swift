import Foundation

/// Small catalog records are safe to keep in memory; content stays in each meeting folder.
struct MeetingListEntry: Codable, Identifiable, Equatable {
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
    @discardableResult func ensureMeetingLoaded(id: UUID) -> Bool {
        if meetings.contains(where: { $0.id == id }) { return true }
        do {
            let value = try MeetingFolderStorage.read(id: id, directory: dataDirectory)
            meetings.append(value)
            rememberLoadedMeeting(value)
            evictLoadedMeetings(keeping: id)
            recoverUnadoptedLiveTranscript(value)
            return true
        }
        catch {
            meetingPageError = "Couldn’t load this meeting. \(error.localizedDescription)"
            return false
        }
    }
    func meeting(id: UUID) -> Meeting? {
        guard ensureMeetingLoaded(id: id) else { return nil }
        guard let value = meetings.first(where: { $0.id == id }) else { return nil }
        guard recordingID != id else { return value }
        let resolved = voiceLibrary.applyingDecisions(to: value)
        if resolved != value, libraryWritable { _ = updateMeeting(resolved) }
        return resolved
    }
    func resetMeetingPages(evictLoaded: Bool = false) {
        meetingPrefetch.reset()
        isLoadingMeetingPage = false
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
    func refreshMeetingPagesAfterSave(previousIDs: Set<UUID>) {
        meetingPrefetch.reset()
        isLoadingMeetingPage = false
        let count = max(Self.meetingPageSize, meetingCatalog.count)
        do {
            let first = meetingCatalog.first
            if meetingPageHasPrevious, let first {
                let following =
                    try libraryIndex?.page(
                        after: first, limit: count, query: meetingSearch, excludingTagIDs: excludedTagIDs) ?? []
                let updated = try libraryIndex?.entry(id: first.id)
                meetingCatalog = Array(
                    (updated.flatMap { excludedTagIDs.isDisjoint(with: $0.tagIDs) ? [$0] + following : nil }
                        ?? following).prefix(count))
            }
            else {
                meetingCatalog =
                    try libraryIndex?.page(limit: count, query: meetingSearch, excludingTagIDs: excludedTagIDs) ?? []
            }
            visibleMeetingIDs = meetingCatalog.map(\.id)
            meetingPageHasMore = meetingCatalog.count == count
        }
        catch { meetingPageError = error.localizedDescription }
    }
}
