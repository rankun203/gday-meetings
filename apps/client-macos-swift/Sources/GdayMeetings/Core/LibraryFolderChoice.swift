import CryptoKit
import Darwin
import Foundation

/// The preference lives outside the library so an unavailable volume remains recoverable.
struct LibraryFolderPreference: Codable {
    let path: String
    let bookmark: Data
    static let key = "libraryFolder"

    init(url: URL) throws {
        path = url.path
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolve() throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
            bookmarkDataIsStale: &stale)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw MeetingError.message(
                "The selected data folder is unavailable. Reconnect its volume or choose another folder in Settings → Data."
            )
        }
        return url
    }
    static func load(defaults: UserDefaults = .standard) -> Self? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    func save(defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// Explicit Preview/test roots keep their pending choice in memory, never in app preferences.
final class LibraryFolderPreferences {
    private let defaults: UserDefaults?
    private var memory: Data?
    init(defaults: UserDefaults?) { self.defaults = defaults }
    var data: Data? {
        get { defaults?.data(forKey: LibraryFolderPreference.key) ?? memory }
        set {
            if let defaults {
                if let newValue {
                    defaults.set(newValue, forKey: LibraryFolderPreference.key)
                }
                else {
                    defaults.removeObject(forKey: LibraryFolderPreference.key)
                }
            }
            else {
                memory = newValue
            }
        }
    }
}

enum LibraryFolderChoice {
    enum Kind { case empty, library }
    static func inspect(_ target: URL, current: URL) throws -> Kind {
        let target = target.resolvingSymlinksInPath().standardizedFileURL
        let current = current.resolvingSymlinksInPath().standardizedFileURL
        guard target != current, !target.path.hasPrefix(current.path + "/"),
            !current.path.hasPrefix(target.path + "/")
        else { throw MeetingError.message("Choose a folder outside the current data folder.") }
        let names = try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0 != ".DS_Store" }
        if names.isEmpty { return .empty }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("meetings").path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw MeetingError.message("Choose an empty folder or an existing Gday Meetings data folder.") }
        return .library
    }

    static func indexDirectory(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gdaymeetings.macos/libraries/" + digest, isDirectory: true)
    }

    /// Copy to an app-owned sibling, verify every byte, then publish into the still-empty destination.
    /// Existing source data is never removed and a partial copy is never selected.
    static func copyLibrary(from source: URL, to target: URL, progress: @Sendable (Int) -> Void) throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let target = target.resolvingSymlinksInPath().standardizedFileURL
        guard try inspect(target, current: source) == .empty else {
            throw MeetingError.message("Copying requires an empty destination folder.")
        }
        let manager = FileManager.default
        let staging = target.deletingLastPathComponent().appendingPathComponent(".gday-copy-" + UUID().uuidString)
        try manager.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let excluded = [
            "index.db", "index.db-wal", "index.db-shm", "index.db.md", "index.db.needs-recovery", ".directory-index.db",
            ".directory-index.db-wal",
            ".directory-index.db-shm", "tasks-index.sqlite", "tasks-index.sqlite-wal", "tasks-index.sqlite-shm",
            "cache", "caches", "staging", ".index-events.json", ".DS_Store",
        ]
        let children = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { !excludedRootEntry($0.lastPathComponent, excluding: excluded) }
        let initialManifest = try manifest(source, excluding: excluded)
        var count = 0
        for child in children {
            try Task.checkCancellation()
            let copy = staging.appendingPathComponent(child.lastPathComponent)
            try copyAndVerify(original: child, copy: copy, count: &count, progress: progress)
        }
        guard initialManifest == (try manifest(source, excluding: excluded)),
            initialManifest == (try manifest(staging, excluding: excluded))
        else {
            throw MeetingError.message(
                "The data folder changed during copying. Wait for edits and syncing to finish, then try again.")
        }
        try manager.createDirectory(at: staging.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        progress(count)
        try Task.checkCancellation()
        // rmdir refuses a destination populated by another process; never recursively remove it.
        let ignored = target.appendingPathComponent(".DS_Store")
        if manager.fileExists(atPath: ignored.path) { try manager.removeItem(at: ignored) }
        guard rmdir(target.path) == 0 else {
            throw MeetingError.message(
                "The destination folder changed during copying. Choose an empty folder and try again.")
        }
        do { try manager.moveItem(at: staging, to: target) }
        catch {
            try? manager.createDirectory(at: target, withIntermediateDirectories: false)
            throw error
        }
    }

    private static func excludedRootEntry(_ name: String, excluding: [String]) -> Bool {
        let recoveryCopy = ["index.db", ".directory-index.db", "tasks-index.sqlite"].contains { base in
            ["", "-wal", "-shm"].contains { name.hasPrefix(base + $0 + ".corrupt-") }
        }
        return excluding.contains(name) || name.hasPrefix(".index") || recoveryCopy
    }

    private static func copyAndVerify(original: URL, copy: URL, count: inout Int, progress: @Sendable (Int) -> Void)
        throws
    {
        try Task.checkCancellation()
        let values = try original.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw MeetingError.message(
                "The data folder contains a symbolic link. Copy its original files into the library before changing folders."
            )
        }
        if values.isDirectory == true {
            let originals = try FileManager.default.contentsOfDirectory(atPath: original.path).sorted()
            try FileManager.default.createDirectory(
                at: copy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in originals {
                try copyAndVerify(
                    original: original.appendingPathComponent(name), copy: copy.appendingPathComponent(name),
                    count: &count, progress: progress)
            }
            guard originals == (try FileManager.default.contentsOfDirectory(atPath: original.path).sorted()) else {
                throw MeetingError.message(
                    "The data folder changed during copying. Try again after its files finish syncing.")
            }
        }
        else {
            let input = try FileHandle(forReadingFrom: original)
            defer { try? input.close() }
            guard
                FileManager.default.createFile(atPath: copy.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw MeetingError.message("Couldn’t create a file in the new data folder.")
            }
            let output = try FileHandle(forWritingTo: copy)
            defer { try? output.close() }
            while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: bytes)
            }
            try output.synchronize()
            guard try hash(original) == hash(copy) else {
                throw MeetingError.message("A file changed during copying. Try again after its files finish syncing.")
            }
            count += 1
            if count % 20 == 0 { progress(count) }
        }
    }
    /// A bounded digest catches changes to already-verified files and root entries.
    private static func manifest(_ root: URL, excluding: [String]) throws -> SHA256.Digest {
        var digest = SHA256()
        func visit(_ file: URL, relative: String) throws {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MeetingError.message(
                    "The data folder contains a symbolic link. Copy its original files into the library before changing folders."
                )
            }
            digest.update(data: Data((relative + "\0").utf8))
            if values.isDirectory == true {
                digest.update(data: Data([0]))
                for name in try FileManager.default.contentsOfDirectory(atPath: file.path).sorted() {
                    try visit(file.appendingPathComponent(name), relative: relative + "/" + name)
                }
            }
            else {
                digest.update(data: Data([1]))
                digest.update(data: Data(try hash(file)))
            }
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        where !excludedRootEntry(name, excluding: excluding) {
            try visit(root.appendingPathComponent(name), relative: name)
        }
        return digest.finalize()
    }

    private static func hash(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
        }
        return hasher.finalize()
    }
}
