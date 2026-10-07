import Foundation

struct CanonicalMeetingArtifact: Sendable {
    var meetingID: UUID
    var name: String
    var data: Data
    /// Exact prior bytes, including absence, protect externally edited history.
    var previous: Data?
}

/// Immutable command; only the background worker owns its transaction and voice persistence instance.
struct CanonicalLibraryWrite: Sendable {
    var current: LibrarySnapshot
    var previous: LibrarySnapshot
    var directory: URL
    var recordingID: UUID?
    var personMerge: PersonMerge?
    var index: LibraryIndex?
    var indexIsBuilding: Bool
    var voice: VoiceLibraryStore.CanonicalCommit?
    var artifacts: [CanonicalMeetingArtifact] = []
    var validateInputs: (@Sendable () throws -> Void)? = nil
}

struct CanonicalLibraryResult: Sendable {
    var committed: Bool
    var requiresRecovery = false
    var error: String?
    var warning: String?
    var indexError: String?
    var changedPaths: [URL] = []
    var voiceState: VoiceLibraryPersistence.Snapshot?
    var voiceStateRefreshFailed = false
}

enum CanonicalLibraryWriter {
    static func write(_ input: CanonicalLibraryWrite) -> CanonicalLibraryResult {
        let dataDirectory = input.directory
        let meetings = input.current.meetings
        let people = input.current.people
        let tags = input.current.tags
        let contextualChats = input.current.contextualChats
        let lastSavedLibrary = input.previous
        let recordingID = input.recordingID
        let personMerge = input.personMerge
        let libraryIndex = input.index
        var warning: String?
        var voiceStateRefreshFailed = false
        var indexError: String?
        var changedPaths: [URL] = []
        var voiceWorker: VoiceLibraryPersistence?
        func directory(for id: UUID) -> URL { MeetingFolderStorage.folder(id: id, directory: dataDirectory) }
        var transaction = LibraryFileTransaction(root: dataDirectory)
        var mergedEntries: [MeetingListEntry] = []
        do {
            try input.validateInputs?()
            for artifact in input.artifacts {
                guard meetings.contains(where: { $0.id == artifact.meetingID }) else {
                    throw MeetingError.message("The artifact’s meeting is unavailable.")
                }
                let folder = directory(for: artifact.meetingID)
                try PrivateTranscriptFile.validatePath(name: artifact.name, at: folder)
                let target = folder.appendingPathComponent(artifact.name)
                let previous = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
                guard previous == artifact.previous else {
                    throw MeetingError.message("Speaker history changed on disk. Reload the meeting before saving.")
                }
                try transaction.remember(target)
            }
            if let voice = input.voice {
                let worker = try VoiceLibraryPersistence(directory: dataDirectory, write: voice.persistence.write)
                worker.adopt(voice.persistence)
                voiceWorker = worker
                try worker.commit(previous: voice.previous, next: voice.next, transaction: &transaction)
            }
            let changed = meetings.filter { meeting in
                lastSavedLibrary.meetings.first(where: { $0.id == meeting.id }) != meeting
            }
            for meeting in changed {
                _ = try MeetingFolderLocation.resolve(id: meeting.id, directory: dataDirectory, date: meeting.createdAt)
            }
            func writesTranscript(_ meeting: Meeting) -> Bool {
                let prior = lastSavedLibrary.meetings.first { $0.id == meeting.id }
                return recordingID != meeting.id && (prior == nil || prior?.transcript != meeting.transcript)
            }
            func documentNames(for meeting: Meeting) -> [String] {
                var names = ["metadata.json", "content.json", "summary.md"]
                if writesTranscript(meeting) { names.append(TranscriptStorage.filename) }
                names += input.artifacts.filter { $0.meetingID == meeting.id }.map(\.name)
                return names
            }
            let dataEventBaselines = Dictionary(
                uniqueKeysWithValues: changed.map { meeting in
                    (
                        meeting.id,
                        DataEventJournal.documentSnapshot(
                            directory: directory(for: meeting.id), names: documentNames(for: meeting))
                    )
                })
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
                var names = documentNames(for: meeting)
                if writesTranscript(meeting) { names.append(LiveTranscriptProjection.checkpointName) }
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
            for meeting in meetings where lastSavedLibrary.meetings.first(where: { $0.id == meeting.id }) != meeting {
                try MeetingFolderStorage.write(
                    meeting, directory: dataDirectory, writeTranscript: writesTranscript(meeting))

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
            // Artifacts and review examples become durable with the same meeting
            // completion receipt. A crash before commit restores all of them.
            for artifact in input.artifacts {
                try PrivateTranscriptFile.write(
                    artifact.data, name: artifact.name,
                    at: directory(for: artifact.meetingID), recordEvent: false)
            }
            try input.validateInputs?()
            try transaction.commit()
            do { try voiceWorker?.reloadRevision(committed: true) }
            catch {
                voiceStateRefreshFailed = true
                warning =
                    "Files were saved, but the voice-library state couldn’t be refreshed. " + error.localizedDescription
            }
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
                    warning =
                        "People were merged, but their data events couldn’t be saved. \(error.localizedDescription)"
                }
            }
            for meeting in changed {
                do {
                    let folder = directory(for: meeting.id)
                    try DataEventJournal.recordDocuments(
                        directory: folder, names: documentNames(for: meeting),
                        previous: dataEventBaselines[meeting.id] ?? [:])
                    let previousAudio = lastSavedLibrary.meetings.first { $0.id == meeting.id }?.audioFiles ?? []
                    for name in meeting.audioFiles where !previousAudio.contains(name) {
                        try DataEventJournal.fileSaved(
                            folder.appendingPathComponent(name), action: .created, directory: folder)
                    }
                }
                catch {
                    warning =
                        "Files were saved, but their data events couldn’t be saved. \(error.localizedDescription)"
                }
            }
            do {
                if !input.indexIsBuilding {
                    for meeting in changed { try libraryIndex?.upsert(MeetingListEntry(meeting), refreshSearch: false) }
                    for entry in mergedEntries { try libraryIndex?.upsert(entry, refreshSearch: false) }
                    let paths = (changed.map(\.id) + mergedEntries.map(\.id)).map {
                        directory(for: $0).appendingPathComponent("metadata.json")
                    }
                    changedPaths = paths
                }
            }
            catch { indexError = "Couldn’t refresh the index. Rebuild it in Data settings." }
            return CanonicalLibraryResult(
                committed: true, warning: warning, indexError: indexError,
                changedPaths: changedPaths, voiceState: voiceWorker?.snapshot(),
                voiceStateRefreshFailed: voiceStateRefreshFailed)
        }
        catch {
            do { try transaction.restore() }
            catch {
                return CanonicalLibraryResult(
                    committed: false, requiresRecovery: true,
                    error:
                        "Couldn’t restore the interrupted save. Reopen the library to recover it. \(error.localizedDescription)"
                )
            }
            do { try voiceWorker?.reloadRevision(committed: false) }
            catch { voiceStateRefreshFailed = true }
            return CanonicalLibraryResult(
                committed: false, error: error.localizedDescription, voiceState: voiceWorker?.snapshot(),
                voiceStateRefreshFailed: voiceStateRefreshFailed)
        }
    }
}
