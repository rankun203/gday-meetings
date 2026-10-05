import Foundation

/// Serial filesystem work stays off the main actor, including preview cleanup and receipts.
actor NotesFileWorker {
    struct WriteResult: Sendable {
        var receiptWarning: (any Error)?
        var cleanupError: (any Error)?
    }
    let directory: URL
    private let beforeWrite: (@Sendable (UUID, String) throws -> Void)?
    private let beforeRead: (@Sendable (UUID) throws -> Void)?

    init(
        directory: URL, beforeWrite: (@Sendable (UUID, String) throws -> Void)? = nil,
        beforeRead: (@Sendable (UUID) throws -> Void)? = nil
    ) {
        self.directory = directory
        self.beforeWrite = beforeWrite
        self.beforeRead = beforeRead
    }
    func folder(_ id: UUID) throws -> URL {
        try MeetingFolderLocation.resolve(id: id, directory: directory)
    }
    func read(_ id: UUID) throws -> String? {
        try beforeRead?(id)
        let file = try folder(id).appendingPathComponent("notes.md")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }
    func export(_ meeting: Meeting, to destination: URL) throws {
        try MeetingExport.write(meeting, directory: folder(meeting.id), to: destination)
    }
    func write(_ id: UUID, text: String, previous: String?) throws -> WriteResult {
        try beforeWrite?(id, text)
        let file = try folder(id).appendingPathComponent("notes.md")
        let previousBytes = try? Data(contentsOf: file)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: file.path) {
            let external = try String(contentsOf: file, encoding: .utf8)
            if let previous, external != previous, external != text {
                // Keep every conflicting external copy, including repeated edits.
                var backup = file.deletingLastPathComponent().appendingPathComponent("notes (changed on disk).md")
                var number = 2
                while FileManager.default.fileExists(atPath: backup.path) {
                    backup = file.deletingLastPathComponent().appendingPathComponent(
                        "notes (changed on disk \(number)).md")
                    number += 1
                }
                try Data(external.utf8).write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                DataEventJournal.recordCreatedFile(backup, directory: file.deletingLastPathComponent())
            }
        }
        try NotesImageStore.ensurePreviews(in: text, directory: file.deletingLastPathComponent())
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var result = WriteResult()
        do { try DataEventJournal.fileChanged(file, previous: previousBytes) }
        catch { result.receiptWarning = error }
        do { try NotesImageStore.cleanupManagedPreviews(in: text, directory: file.deletingLastPathComponent()) }
        catch { result.cleanupError = error }
        return result
    }
}

/// Drafts are immediate; explicit flushes wait for the latest durable revision.
@MainActor
final class NotesStorage {
    let directory: URL
    var saved: [UUID: String] = [:]
    private(set) var pending: [UUID: String] = [:]
    private var revisions: [UUID: UInt64] = [:]
    private var readRequests: [UUID: UUID] = [:]
    private var deletions = Set<UUID>()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var writes: [UUID: Task<Void, Error>] = [:]
    var onError: ((Error) -> Void)?
    private let worker: NotesFileWorker
    private var watcher: NotesFileWatcher?
    private var watchedID: UUID?
    private var watchGeneration = UUID()

    init(directory: URL, worker: NotesFileWorker? = nil) {
        self.directory = directory
        self.worker = worker ?? NotesFileWorker(directory: directory)
    }
    func url(_ id: UUID) -> URL {
        MeetingFolderStorage.folder(id: id, directory: directory).appendingPathComponent("notes.md")
    }
    func revision(_ id: UUID) -> UInt64 { revisions[id, default: 0] }
    func isDeleting(_ id: UUID) -> Bool { deletions.contains(id) }
    func reserveDeletion(_ id: UUID) -> Bool { deletions.insert(id).inserted }
    func releaseDeletion(_ id: UUID) { deletions.remove(id) }

    func load(_ id: UUID, fallback: String) async throws -> String {
        let request = UUID()
        readRequests[id] = request
        if pending[id] != nil { try await flush(id) }
        let revision = revision(id)
        let value = try await worker.read(id) ?? fallback
        guard readRequests[id] == request, revision == self.revision(id), pending[id] == nil else {
            return pending[id] ?? saved[id] ?? fallback
        }
        if saved[id] != value { revisions[id, default: 0] &+= 1 }
        saved[id] = value
        return value
    }
    func schedule(_ id: UUID, text: String) {
        guard !isDeleting(id) else { return }
        pending[id] = text
        revisions[id, default: 0] &+= 1
        tasks.removeValue(forKey: id)?.cancel()
        tasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self else { return }
            self.tasks.removeValue(forKey: id)
            do { try await self.flush(id) }
            catch { self.onError?(error) }
        }
    }
    func flush(_ id: UUID) async throws {
        tasks.removeValue(forKey: id)?.cancel()
        while let value = pending[id] {
            tasks.removeValue(forKey: id)?.cancel()
            if let write = writes[id] {
                try await write.value
                continue
            }
            let revision = revision(id)
            let previous = saved[id]
            let worker = worker
            // Install the in-flight operation before yielding so concurrent flushes join it.
            let write = Task { @MainActor in
                defer { self.writes.removeValue(forKey: id) }
                let result = try await worker.write(id, text: value, previous: previous)
                self.saved[id] = value
                if let warning = result.receiptWarning { self.onError?(warning) }
                if let failure = result.cleanupError { throw failure }
                if self.revision(id) == revision { self.pending.removeValue(forKey: id) }
            }
            writes[id] = write
            try await write.value
        }
    }
    func flushAll() async throws {
        while let id = pending.keys.first { try await flush(id) }
    }
    func write(_ id: UUID, text: String) async throws {
        guard !isDeleting(id) else { throw ServiceError("This meeting is being moved to the Trash.") }
        if saved[id] == text, pending[id] == nil { return }
        schedule(id, text: text)
        try await flush(id)
    }
    func export(_ meeting: Meeting, to destination: URL) async throws {
        try await worker.export(meeting, to: destination)
    }
    func discard(_ id: UUID) async throws {
        stopWatching(id)
        tasks.removeValue(forKey: id)?.cancel()
        if let write = writes[id] { try await write.value }
        guard pending[id] == nil else {
            throw ServiceError("Save the latest meeting notes before discarding their draft.")
        }
        saved.removeValue(forKey: id)
        readRequests.removeValue(forKey: id)
        revisions[id, default: 0] &+= 1
    }
    func watch(_ id: UUID, reloaded: @escaping (String) -> Void) async throws {
        watcher?.stop()
        watchedID = id
        watchGeneration = UUID()
        let generation = watchGeneration
        let folder = try await worker.folder(id)
        guard watchedID == id, watchGeneration == generation else { return }
        let watcher = NotesFileWatcher()
        self.watcher = watcher
        try await watcher.start(directory: folder) { [weak self] in
            Task { @MainActor in
                guard let self, self.watchedID == id, self.watchGeneration == generation else { return }
                do {
                    let text = try await self.reloadExternal(id)
                    guard self.watchedID == id, self.watchGeneration == generation else { return }
                    if let text { reloaded(text) }
                }
                catch { self.onError?(error) }
            }
        }
    }
    func stopWatching(_ id: UUID) {
        guard watchedID == id else { return }
        watcher?.stop()
        watcher = nil
        watchedID = nil
        watchGeneration = UUID()
    }
    /// Pending app drafts win; the serialized writer retains external conflicts.
    func reloadExternal(_ id: UUID) async throws -> String? {
        let request = UUID()
        readRequests[id] = request
        if pending[id] != nil {
            try await flush(id)
            return nil
        }
        let revision = revision(id)
        guard let external = try await worker.read(id) else { return nil }
        guard readRequests[id] == request, revision == self.revision(id), pending[id] == nil else { return nil }
        guard external != saved[id] else { return nil }
        revisions[id, default: 0] &+= 1
        saved[id] = external
        return external
    }
}

extension MeetingStore {
    func editNotes(id: UUID, text: String) {
        guard libraryWritable, !notesStorage.isDeleting(id), let index = meetings.firstIndex(where: { $0.id == id })
        else { return }
        meetings[index].notes = text
        notesStorage.schedule(id, text: text)
    }
    @discardableResult func flushNotes() async -> Bool {
        guard libraryWritable else { return true }
        do {
            try await notesStorage.flushAll()
            return true
        }
        catch {
            errorMessage = "Couldn’t save meeting notes. \(error.localizedDescription)"
            return false
        }
    }
    func openNotes(id: UUID) async {
        guard let value = meetings.first(where: { $0.id == id }) else { return }
        let storage = notesStorage
        do {
            let text = try await storage.load(id, fallback: value.notes)
            guard !Task.isCancelled, notesStorage === storage,
                let index = meetings.firstIndex(where: { $0.id == id })
            else { return }
            meetings[index].notes = text
            try await storage.watch(id) { [weak self, weak storage] text in
                guard let self, let storage, self.notesStorage === storage,
                    let index = self.meetings.firstIndex(where: { $0.id == id })
                else { return }
                self.meetings[index].notes = text
            }
        }
        catch { errorMessage = "Couldn’t open meeting notes. \(error.localizedDescription)" }
    }
    func closeNotes(id: UUID) async {
        notesStorage.stopWatching(id)
        _ = await flushNotes()
    }
}
