import Darwin
import Foundation

/// CLSP retrieval artifacts are derived and have a dedicated provider directory.
/// Recordings, transcripts, people and Community-1 voice representations are never touched.
enum RetiredVoiceSearchMigration {
    static let providerID = "E21BE59C-BDBE-4525-9379-D21066E08E8A"

    /// Remove retired weights and only their now-unreferenced hard-linked cache objects.
    static func removeModels(root: URL) throws {
        let fm = FileManager.default
        let retired = root.appendingPathComponent("clsp", isDirectory: true)
        guard fm.fileExists(atPath: retired.path) else { return }
        for parent in [root, retired] {
            guard (try parent.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw ServiceError("Couldn’t remove retired models because their folder is a link.")
            }
        }
        var identities: Set<String> = []
        var enumerationError: Error?
        guard
            let files = fm.enumerator(
                at: retired, includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                })
        else { throw ServiceError("Couldn’t read retired models before removing them.") }
        do {
            while let file = files.nextObject() as? URL {
                try Task.checkCancellation()
                var info = stat()
                if lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                    identities.insert("\(info.st_dev):\(info.st_ino)")
                }
            }
        }
        if let enumerationError { throw enumerationError }
        try Task.checkCancellation()
        try fm.removeItem(at: retired)
        let objects = root.appendingPathComponent("objects", isDirectory: true)
        guard fm.fileExists(atPath: objects.path),
            (try objects.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
        else { return }
        // Finish this small ownership-based cleanup once the retired links are removed.
        for object in try fm.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) {
            var info = stat()
            if lstat(object.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                identities.contains("\(info.st_dev):\(info.st_ino)")
            {
                try fm.removeItem(at: object)
            }
        }
    }

    static func removeIndexNamespace(indexDirectory: URL) throws {
        let url = indexDirectory.appendingPathComponent("index.db")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try Task.checkCancellation()
        let connection = try IndexDatabase.open(at: url)
        try connection.retireVoiceSearchNamespace()
    }

    static func removeArtifacts(directory: URL, indexDirectory: URL) throws {
        let marker = indexDirectory.appendingPathComponent("retired-voice-search-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let root = directory.appendingPathComponent("meetings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
            try Data("1".utf8).write(to: marker, options: .atomic)
            return
        }
        var enumerationError: Error?
        if let folders = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            })
        {
            while let folder = folders.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let providers = folder.appendingPathComponent("providers", isDirectory: true)
                let retired = providers.appendingPathComponent(providerID, isDirectory: true)
                let embeddings = retired.appendingPathComponent("embeddings", isDirectory: true)
                // Never follow a replaced parent into unrelated storage.
                for parent in [providers, retired] where FileManager.default.fileExists(atPath: parent.path) {
                    guard (try parent.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                        throw ServiceError("Couldn’t remove retired voice search data because its folder is a link.")
                    }
                }
                if FileManager.default.fileExists(atPath: embeddings.path) {
                    try FileManager.default.removeItem(at: embeddings)
                }
            }
        }
        if let enumerationError { throw enumerationError }
        if FileManager.default.fileExists(atPath: root.path),
            !FileManager.default.isReadableFile(atPath: root.path)
        {
            throw ServiceError("Couldn’t read meeting folders to remove retired voice search data.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: marker, options: .atomic)
    }
}
