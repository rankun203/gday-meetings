import Foundation

/// Folder names are labels; the base36 suffix remains the meeting identity.
enum MeetingFolderLocation {
    enum AccessError: LocalizedError {
        case duplicate, symbolicLink, invalidPath
        var errorDescription: String? {
            switch self {
            case .duplicate:
                return "Multiple folders have this meeting ID. Remove the duplicate folder, then rebuild the index."
            case .symbolicLink:
                return "The meeting folder uses a symbolic link. Choose a folder stored inside this library."
            case .invalidPath: return "The meeting folder is outside this library."
            }
        }
    }
    private final class Location {
        let name: String
        let reserved: Bool
        init(_ name: String, reserved: Bool = false) {
            self.name = name
            self.reserved = reserved
        }
    }
    private static let folders = NSCache<NSString, Location>()
    private final class IndexReference {
        weak var value: LibraryIndex?
        init(_ value: LibraryIndex) { self.value = value }
    }
    private final class IndexReferences { var values: [IndexReference] = [] }
    private static let indexes = NSCache<NSString, IndexReferences>()
    private static let indexLock = NSLock()
    static func identity(_ name: String) -> UUID? {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        if parts.count == 1 { return MeetingIdentity.parse(name) }
        guard parts.count == 2, parts[0].count == 8,
            parts[0].utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        return MeetingIdentity.parse(String(parts[1]))
    }
    static func name(id: UUID, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d_", parts.year!, parts.month!, parts.day!) + MeetingIdentity.string(id)
    }
    private static func key(_ id: UUID, _ directory: URL) -> NSString {
        (directory.standardizedFileURL.path + "/" + id.uuidString) as NSString
    }
    static func remember(_ folder: URL, id: UUID, directory: URL) {
        folders.countLimit = 512
        folders.setObject(Location(folder.lastPathComponent), forKey: key(id, directory))
    }
    static func block(id: UUID, directory: URL) {
        folders.setObject(Location(""), forKey: key(id, directory))
    }
    static func forget(id: UUID, directory: URL) { folders.removeObject(forKey: key(id, directory)) }
    static func registerIndex(_ index: LibraryIndex) {
        indexLock.lock()
        defer { indexLock.unlock() }
        indexes.countLimit = 32
        let key = index.directory.standardizedFileURL.path as NSString
        let references = indexes.object(forKey: key) ?? IndexReferences()
        references.values.removeAll { $0.value == nil || $0.value === index }
        references.values.append(IndexReference(index))
        indexes.setObject(references, forKey: key)
    }
    static func registeredIndex(directory: URL) -> LibraryIndex? {
        indexLock.lock()
        defer { indexLock.unlock() }
        let references = indexes.object(forKey: directory.standardizedFileURL.path as NSString)
        references?.values.removeAll { $0.value == nil }
        return references?.values.last?.value
    }
    static func validate(_ folder: URL, directory: URL) throws {
        let root = directory.appendingPathComponent("meetings")
        guard folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
            throw AccessError.invalidPath
        }
        for path in [root, folder] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil {
                throw AccessError.symbolicLink
            }
        }
    }
    /// A nonthrowing display caller must never receive a writable replacement for an unsafe folder.
    static func unavailable(id: UUID) -> URL {
        URL(fileURLWithPath: "/dev/null").appendingPathComponent("meeting-" + id.uuidString)
    }
    static func newFolder(id: UUID, date: Date, directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent("meetings").appendingPathComponent(name(id: id, date: date))
        try validate(folder, directory: directory)
        folders.countLimit = 512
        folders.setObject(Location(folder.lastPathComponent, reserved: true), forKey: key(id, directory))
        return folder
    }
    static func candidates(id: UUID, directory: URL) throws -> [URL] {
        let root = directory.appendingPathComponent("meetings")
        try validate(root.appendingPathComponent(MeetingIdentity.string(id)), directory: directory)
        guard
            let entries = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }
        var result: [URL] = []
        for case let folder as URL in entries where identity(folder.lastPathComponent) == id {
            try validate(folder, directory: directory)
            if try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                result.append(root.appendingPathComponent(folder.lastPathComponent))
            }
        }
        return result
    }
    static func resolve(id: UUID, directory: URL, date: Date = Date()) throws -> URL {
        let root = directory.appendingPathComponent("meetings")
        let proposed = root.appendingPathComponent(name(id: id, date: date))
        try validate(proposed, directory: directory)
        if let name = try registeredIndex(directory: directory)?.folderName(id: id) {
            guard !name.isEmpty else { throw AccessError.duplicate }
            guard identity(name) == id else { throw AccessError.invalidPath }
            let candidate = root.appendingPathComponent(name)
            try validate(candidate, directory: directory)
            if FileManager.default.fileExists(atPath: candidate.path) {
                remember(candidate, id: id, directory: directory)
                return candidate
            }
        }
        if let cached = folders.object(forKey: key(id, directory)) {
            guard !cached.name.isEmpty else { throw AccessError.duplicate }
            let candidate = root.appendingPathComponent(cached.name)
            try validate(candidate, directory: directory)
            if cached.reserved || FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let matches = try candidates(id: id, directory: directory)
        guard matches.count <= 1 else { throw AccessError.duplicate }
        if let existing = matches.first {
            remember(existing, id: id, directory: directory)
            return existing
        }
        return proposed
    }
}
