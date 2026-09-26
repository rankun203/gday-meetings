import Foundation

/// A newer build saved this library. It is opened read-only and never rewritten,
/// so the newer build still finds its own layout.
struct NewerLibraryVersionError: LocalizedError, Equatable {
    static let title = "This library was saved by a newer version of Gday Meetings."
    static let recovery =
        "Install the latest version of Gday Meetings to open it. This version doesn’t change the library."
    static var message: String { "\(title) \(recovery)" }
    let version: Int
    var errorDescription: String? { Self.message }
}

extension MeetingLibrary {
    private struct VersionOnly: Decodable { var version: Int? }

    /// Reads `library.json` under the contract on `MeetingLibrary`. The version is
    /// checked before the full decode, so a newer layout that no longer decodes
    /// still reports the newer version. An older library is copied to
    /// `library-v<N>-backup.json` before its migrations run; the caller saves the
    /// result when `migrated` is true.
    static func load(
        from url: URL, supportedVersion: Int = currentVersion, migrations: [Int: Migration] = migrations
    ) throws -> (library: MeetingLibrary, migrated: Bool) {
        let data = try Data(contentsOf: url)
        let found = try JSONDecoder().decode(VersionOnly.self, from: data).version ?? 1
        guard found <= supportedVersion else { throw NewerLibraryVersionError(version: found) }
        var library = try JSONDecoder().decode(MeetingLibrary.self, from: data)
        guard found < supportedVersion else { return (library, false) }
        let backup = url.deletingLastPathComponent().appendingPathComponent("library-v\(found)-backup.json")
        // Keep the first backup: a retried migration must not replace the original.
        if !FileManager.default.fileExists(atPath: backup.path) {
            try data.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        while library.version < supportedVersion {
            guard let step = migrations[library.version] else {
                throw MeetingError.message(
                    "This library uses format version \(library.version), which this version of Gday Meetings can’t upgrade."
                )
            }
            if library.version == 2, supportedVersion >= 3 {
                for meeting in library.meetings where !meeting.notes.isEmpty {
                    let folder = url.deletingLastPathComponent().appendingPathComponent(meeting.id.uuidString)
                    let notes = folder.appendingPathComponent("notes.md")
                    if !FileManager.default.fileExists(atPath: notes.path) {
                        try FileManager.default.createDirectory(
                            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try Data(meeting.notes.utf8).write(to: notes, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notes.path)
                    }
                }
            }
            try step(&library)
            library.version += 1
        }
        return (library, true)
    }
}
