import Foundation

/// Sidecar persistence keeps typing independent of library metadata writes.
@MainActor
final class NotesStorage {
    let directory: URL
    var saved: [UUID: String] = [:]
    var pending: [UUID: String] = [:]
    var tasks: [UUID: Task<Void, Never>] = [:]
    var onError: ((Error) -> Void)?
    private var watcher: NotesFileWatcher?
    private var watchedID: UUID?
    init(directory: URL) { self.directory = directory }
    func url(_ id: UUID) -> URL {
        MeetingFolderStorage.folder(id: id, directory: directory).appendingPathComponent("notes.md")
    }
    func load(_ id: UUID, fallback: String) throws -> String {
        let file = url(id)
        let value =
            FileManager.default.fileExists(atPath: file.path)
            ? try String(contentsOf: file, encoding: .utf8) : fallback
        saved[id] = value
        return value
    }
    func schedule(_ id: UUID, text: String) {
        pending[id] = text
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }
            guard let self else { return }
            do { try self.flush(id) }
            catch { self.onError?(error) }
        }
    }
    func flush(_ id: UUID) throws {
        tasks.removeValue(forKey: id)?.cancel()
        guard let value = pending[id] else { return }
        try write(id, text: value)
        pending.removeValue(forKey: id)
    }
    func flushAll() throws { for id in Array(pending.keys) { try flush(id) } }
    func write(_ id: UUID, text: String) throws {
        let file = url(id)
        if saved[id] == text, pending[id] == nil { return }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: file.path) {
            let external = try String(contentsOf: file, encoding: .utf8)
            if let previous = saved[id], external != previous, external != text {
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
            }
        }
        try NotesImageStore.ensurePreviews(in: text, directory: file.deletingLastPathComponent())
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        saved[id] = text
        try NotesImageStore.cleanupManagedPreviews(in: text, directory: file.deletingLastPathComponent())
    }
    func discard(_ id: UUID) {
        stopWatching(id)
        tasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)
        saved.removeValue(forKey: id)
    }
    func watch(_ id: UUID, reloaded: @escaping (String) -> Void) throws {
        watcher?.stop()
        watchedID = id
        let watcher = NotesFileWatcher()
        try watcher.start(directory: url(id).deletingLastPathComponent()) { [weak self] in
            guard let self, self.watchedID == id else { return }
            do {
                if let text = try self.reloadExternal(id) { reloaded(text) }
            }
            catch { self.onError?(error) }
        }
        self.watcher = watcher
    }
    func stopWatching(_ id: UUID) {
        guard watchedID == id else { return }
        watcher?.stop()
        watcher = nil
        watchedID = nil
    }
    /// Returns only an external replacement. A pending app draft wins, with
    /// write() retaining the conflicting disk copy before its atomic save.
    func reloadExternal(_ id: UUID) throws -> String? {
        guard FileManager.default.fileExists(atPath: url(id).path) else { return nil }
        let external = try String(contentsOf: url(id), encoding: .utf8)
        guard external != saved[id] else { return nil }
        if pending[id] != nil {
            try flush(id)
            return nil
        }
        saved[id] = external
        return external
    }
}

extension MeetingStore {
    func editNotes(id: UUID, text: String) {
        guard libraryWritable, let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].notes = text
        notesStorage.schedule(id, text: text)
    }
    @discardableResult func flushNotes() -> Bool {
        guard libraryWritable else { return true }
        do {
            try notesStorage.flushAll()
            return true
        }
        catch {
            errorMessage = "Couldn’t save meeting notes. \(error.localizedDescription)"
            return false
        }
    }
    func openNotes(id: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        do {
            if notesStorage.pending[id] != nil { try notesStorage.flush(id) }
            meetings[index].notes = try notesStorage.load(id, fallback: meetings[index].notes)
            if FileManager.default.fileExists(atPath: directory(for: id).path) {
                try notesStorage.watch(id) { [weak self] text in
                    guard let self, let index = self.meetings.firstIndex(where: { $0.id == id }) else { return }
                    self.meetings[index].notes = text
                }
            }
        }
        catch { errorMessage = "Couldn’t open meeting notes. \(error.localizedDescription)" }
    }
    func closeNotes(id: UUID) {
        _ = flushNotes()
        notesStorage.stopWatching(id)
    }
}
