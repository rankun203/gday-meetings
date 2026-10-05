import Foundation

/// Paths are arguments to an owned worker process, never a shell command.
struct LocalSearchConfiguration: Codable, Equatable, Sendable {
    var executableURL: URL?
    var modelCacheURL: URL?

    static let modelID = "yfyeung/CLSP"
    static let modelRevision = "30355ce67960e4cc1562e4e5fa154baf86a21430"
    static let tokenizerRevision = "e2da8e2f811d1448a5b465c236feacd80ffbac7b"

    /// Reads only prepared-model metadata. Never starts Python, downloads, or inference.
    func validatePreparedFiles() throws {
        guard let executableURL, executableURL.isFileURL, executableURL.path.hasPrefix("/"),
            (try? executableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            FileManager.default.isExecutableFile(atPath: executableURL.path)
        else { throw ServiceError("Choose the installed gday-search executable.") }
        guard let modelCacheURL, modelCacheURL.isFileURL, modelCacheURL.path.hasPrefix("/") else {
            throw ServiceError("Choose the prepared search model folder.")
        }
        let root = modelCacheURL.resolvingSymlinksInPath().standardizedFileURL
        let marker = root.appendingPathComponent("gday-clsp-prepared.json").resolvingSymlinksInPath()
            .standardizedFileURL
        guard marker.path.hasPrefix(root.path + "/") else {
            throw ServiceError("The search readiness file must stay inside the selected model folder.")
        }
        let markerSize = try marker.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard markerSize > 0, markerSize <= 1_048_576 else {
            throw ServiceError("Prepare the search model again. Its readiness file is invalid.")
        }
        let manifest = try JSONDecoder().decode(PreparedManifest.self, from: Data(contentsOf: marker))
        guard manifest.version == 1, manifest.modelID == Self.modelID,
            manifest.modelRevision == Self.modelRevision, manifest.tokenizerRevision == Self.tokenizerRevision,
            !manifest.files.isEmpty
        else { throw ServiceError("Prepare the supported search model revision before using this provider.") }
        for file in manifest.files {
            guard !file.path.isEmpty, !file.path.hasPrefix("/"), file.size > 0,
                file.modified.isFinite, file.sha256.count == 64,
                file.sha256.allSatisfy({ $0.isHexDigit })
            else { throw ServiceError("Prepare the search model again. Its file metadata is invalid.") }
            let url = root.appendingPathComponent(file.path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else {
                throw ServiceError("Search model files must stay inside the selected model folder.")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.fileSize == file.size,
                let modified = values.contentModificationDate?.timeIntervalSince1970,
                abs(modified - file.modified) < 0.001
            else { throw ServiceError("Search model files changed. Prepare the model again before searching.") }
        }
    }

    private struct PreparedManifest: Decodable {
        let version: Int
        let modelID: String
        let modelRevision: String
        let tokenizerRevision: String
        let files: [PreparedFile]
    }
    private struct PreparedFile: Decodable {
        let path: String
        let size: Int
        let modified: TimeInterval
        let sha256: String
    }
}
