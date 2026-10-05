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
