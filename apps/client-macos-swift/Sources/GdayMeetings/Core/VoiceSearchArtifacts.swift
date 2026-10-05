import CryptoKit
import Foundation

struct VoiceEmbeddingSpace: Codable, Equatable, Sendable {
    let model: String
    let revision: String
    let preprocessing: String
    let dimension: Int
    let normalization: String

    static let clsp = Self(
        model: "yfyeung/CLSP", revision: "30355ce67960e4cc1562e4e5fa154baf86a21430",
        preprocessing: "clsp-coreml-fp32-kaldi-v1", dimension: 512, normalization: "unitL2")
    init(model: String, revision: String, preprocessing: String, dimension: Int, normalization: String) {
        self.model = model
        self.revision = revision
        self.preprocessing = preprocessing
        self.dimension = dimension
        self.normalization = normalization
    }
    init(_ response: LocalSearchEmbeddingResponse) {
        self.init(
            model: response.model, revision: response.revision, preprocessing: response.preprocessing,
            dimension: response.dimension, normalization: response.normalization)
    }
}

struct VoiceSourceFingerprint: Codable, Equatable, Sendable {
    let bytes: UInt64
    let modified: Date
    let inode: UInt64

    static func read(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ServiceError("The audio source must be a regular file inside its meeting folder.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw ServiceError("Couldn’t read the audio source revision.") }
        return Self(bytes: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }
}

struct VoiceSearchArtifact: Codable, Sendable {
    var schemaVersion = 1
    let meetingID: UUID
    let audioFilename: String
    let sourceRevision: String
    let start: Double
    let duration: Double
    let space: VoiceEmbeddingSpace
    let vector: [Double]

    var sourceID: String {
        VoiceSearchArtifacts.digest(Data((meetingID.uuidString + "\n" + audioFilename + "\n" + sourceRevision).utf8))
    }
    var id: String {
        VoiceSearchArtifacts.digest(
            Data(
                (sourceID + "\n" + String(start.bitPattern) + "\n" + String(duration.bitPattern)
                    + "\n" + space.model + "\n" + space.revision + "\n" + space.preprocessing
                    + "\n" + String(space.dimension) + "\n" + space.normalization).utf8))
    }
    func validate() throws {
        guard schemaVersion == 1, space == .clsp,
            audioFilename == URL(fileURLWithPath: audioFilename).lastPathComponent,
            !audioFilename.isEmpty, audioFilename != ".", audioFilename != "..",
            sourceRevision.count == 64,
            sourceRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            start.isFinite, start >= 0, start < 1_000_000_000_000, duration.isFinite, duration >= 0.25, duration <= 30,
            vector.count == space.dimension, vector.allSatisfy(\.isFinite),
            abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.002
        else { throw SearchProviderError.invalidResponse }
    }
}

/// Portable embeddings are source artifacts. Their database rows can always be rebuilt.
struct VoiceSearchArtifacts: Sendable {
    static let providerID = UUID(uuidString: "E21BE59C-BDBE-4525-9379-D21066E08E8A")!
    let directory: URL
    var root: URL { directory.appendingPathComponent("meetings") }
    private func ownedRoot(in meeting: URL) -> URL {
        meeting.appendingPathComponent("providers").appendingPathComponent(Self.providerID.uuidString)
            .appendingPathComponent("embeddings")
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sourceRevision(_ url: URL) throws -> (String, VoiceSourceFingerprint) {
        let before = try VoiceSourceFingerprint.read(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        guard try VoiceSourceFingerprint.read(url) == before else {
            throw ServiceError(
                "The audio changed while its search revision was being read. Build the voice index again.")
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), before)
    }
    func url(for artifact: VoiceSearchArtifact) -> URL {
        ownedRoot(in: MeetingFolderStorage.folder(id: artifact.meetingID, directory: directory))
            .appendingPathComponent(artifact.sourceID)
            .appendingPathComponent(artifact.id + ".json")
    }
    private func validateOwnedPath(_ url: URL) throws {
        let base = directory.standardizedFileURL
        let path = url.standardizedFileURL
        guard path.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw ServiceError("The embedding artifact is outside this provider’s folder.")
        }
        let components = path.path.dropFirst(root.standardizedFileURL.path.count + 1).split(separator: "/")
        guard components.count >= 4, MeetingFolderLocation.identity(String(components[0])) != nil,
            components[1] == "providers", components[2] == Substring(Self.providerID.uuidString),
            components[3] == "embeddings"
        else { throw ServiceError("The embedding artifact is outside this provider’s folder.") }
        var cursor = path
        while cursor != base {
            guard cursor.path.hasPrefix(base.path + "/") else { throw MeetingFolderLocation.AccessError.invalidPath }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                throw ServiceError("Embedding artifacts cannot use symbolic links.")
            }
            cursor.deleteLastPathComponent()
        }
    }
    func save(_ artifact: VoiceSearchArtifact) throws {
        try artifact.validate()
        let file = url(for: artifact)
        try validateOwnedPath(file)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(artifact)
        guard data.count <= 65_536 else { throw SearchProviderError.invalidResponse }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func read(_ file: URL) throws -> VoiceSearchArtifact {
        try validateOwnedPath(file)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 65_536 else {
            throw SearchProviderError.invalidResponse
        }
        let artifact = try JSONDecoder().decode(VoiceSearchArtifact.self, from: Data(contentsOf: file))
        try artifact.validate()
        guard url(for: artifact).standardizedFileURL == file.standardizedFileURL else {
            throw ServiceError("The embedding artifact identity does not match its filename.")
        }
        return artifact
    }
    func enumerate(_ visit: (URL) throws -> Void) throws {
        try MeetingFolderLocation.validate(root.appendingPathComponent("check"), directory: directory)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard
            let meetings = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return }
        for case let meeting as URL in meetings {
            try Task.checkCancellation()
            let values = try meeting.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                MeetingFolderLocation.identity(meeting.lastPathComponent) != nil
            else { continue }
            // Foundation may return /private/var aliases from enumeration even
            // when the library URL uses /var. Keep absent provider descendants
            // relative to the same validated library root.
            let folder = ownedRoot(in: root.appendingPathComponent(meeting.lastPathComponent))
            try validateOwnedPath(folder)
            guard FileManager.default.fileExists(atPath: folder.path),
                let files = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in files {
                try Task.checkCancellation()
                if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    files.skipDescendants()
                    throw ServiceError("Embedding artifacts cannot use symbolic links.")
                }
                if file.pathExtension == "json" { try visit(file) }
            }
        }
    }
    func remove(meetingID: UUID) throws {
        let folder = ownedRoot(in: MeetingFolderStorage.folder(id: meetingID, directory: directory))
        try validateOwnedPath(folder)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }
}
