import Foundation

struct ExternalLibraryChanges: OptionSet, Sendable {
    var rawValue: Int
    static let meetings = Self(rawValue: 1)
    static let people = Self(rawValue: 2)
    static let tags = Self(rawValue: 4)
    static let tasks = Self(rawValue: 8)
    static let all: Self = [.meetings, .people, .tags, .tasks]

    init(rawValue: Int) { self.rawValue = rawValue }
    init(paths: [URL], root: URL, rebuild: Bool) {
        self = rebuild ? .all : []
        let roots = Set([root.standardized.path, LibraryFileMonitor.canonicalRoot(root).path])
        for url in paths {
            let path = url.standardized.path
            if roots.contains(path) {
                self = .all
                return
            }
            guard let prefix = roots.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            switch path.dropFirst(prefix.count + 1).split(separator: "/").first {
            case "meetings": insert(.meetings)
            case "people": insert(.people)
            case "tags": insert(.tags)
            case "tasks.jsonl": insert(.tasks)
            default: break
            }
        }
    }
}

/// nil IDs means an ancestor/recovery event; an empty set means no meetings.
struct ExternalLibraryChangeBatch: Sendable {
    var changes: ExternalLibraryChanges = []
    var meetingIDs: Set<UUID>? = []

    init(paths: [URL] = [], root: URL, rebuild: Bool = false) {
        changes = .init(paths: paths, root: root, rebuild: rebuild)
        guard changes.contains(.meetings) else { return }
        guard !rebuild else {
            meetingIDs = nil
            return
        }
        let roots = Set([root.standardized.path, LibraryFileMonitor.canonicalRoot(root).path])
        for url in paths {
            let path = url.standardized.path
            if roots.contains(path) {
                meetingIDs = nil
                return
            }
            guard let prefix = roots.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            let components = path.dropFirst(prefix.count + 1).split(separator: "/")
            guard components.first == "meetings" else { continue }
            guard components.count > 1, let id = MeetingFolderLocation.identity(String(components[1])) else {
                meetingIDs = nil
                return
            }
            meetingIDs?.insert(id)
        }
    }

    mutating func formUnion(_ other: Self) {
        changes.formUnion(other.changes)
        if let own = meetingIDs, let incoming = other.meetingIDs {
            meetingIDs = own.union(incoming)
        }
        else {
            meetingIDs = nil
        }
    }
}

struct ExternalMeetingSnapshot: Sendable {
    var meetings: [UUID: Meeting] = [:]
    var removed: Set<UUID> = []
    var errors: [String] = []

    static func read(
        ids: Set<UUID>, directory: URL,
        reader: @Sendable (UUID, URL) throws -> Meeting
    ) -> Self? {
        let marker = directory.appendingPathComponent(".document-transaction").path
        guard !FileManager.default.fileExists(atPath: marker) else { return nil }
        var snapshot = Self()
        for id in ids {
            do {
                let metadata = try MeetingFolderLocation.resolve(id: id, directory: directory)
                    .appendingPathComponent("metadata.json")
                do { _ = try metadata.resourceValues(forKeys: [.isRegularFileKey]) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    snapshot.removed.insert(id)
                    continue
                }
                snapshot.meetings[id] = try reader(id, directory)
            }
            catch { snapshot.errors.append(error.localizedDescription) }
        }
        guard !FileManager.default.fileExists(atPath: marker) else { return nil }
        return snapshot
    }
}

struct ExternalCatalogSnapshot: Sendable {
    let people: [Person]?
    let tags: [MeetingTag]?

    static func read(changes: ExternalLibraryChanges, directory: URL) throws -> Self? {
        let transaction = directory.appendingPathComponent(".document-transaction").path
        guard !FileManager.default.fileExists(atPath: transaction) else { return nil }
        let people =
            changes.contains(.people)
            ? try FileEntityStorage.load(Person.self, kind: "people", directory: directory) : nil
        let tags =
            changes.contains(.tags)
            ? try FileEntityStorage.load(MeetingTag.self, kind: "tags", directory: directory) : nil
        guard !FileManager.default.fileExists(atPath: transaction) else { return nil }
        return Self(people: people, tags: tags)
    }
}
