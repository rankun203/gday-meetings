import Foundation

extension NotesImageStore {
    private struct PreviewIndex: Codable {
        var files: [String: String] = [:]
        var originalVersions: [String: String] = [:]
        var obsolete: Set<String> = []
        init() {}
        enum CodingKeys: CodingKey { case files, originalVersions, obsolete }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            files = try values.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
            originalVersions = try values.decodeIfPresent([String: String].self, forKey: .originalVersions) ?? [:]
            obsolete = try values.decodeIfPresent(Set<String>.self, forKey: .obsolete) ?? []
        }
    }
    private static func previewIndexURL(_ directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("notes-image-previews.json")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw MeetingError.message("The image preview index can’t use a symbolic link.")
        }
        return url
    }
    private static func readPreviewIndex(_ directory: URL) throws -> PreviewIndex {
        let file = try previewIndexURL(directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return PreviewIndex() }
        return try JSONDecoder().decode(PreviewIndex.self, from: Data(contentsOf: file))
    }
    private static func savePreviewIndex(_ index: PreviewIndex, directory: URL) throws {
        let file = try previewIndexURL(directory)
        try JSONEncoder().encode(index).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func originalVersion(_ path: String, directory: URL) throws -> String {
        let file = try NotesAssets.safeURL(relativePath: path, directory: directory)
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values.fileSize ?? 0)"
    }
    static func isManagedPreview(_ path: String) -> Bool {
        guard path.hasPrefix("assets/gday-preview-"),
            ["png", "jpg"].contains((path as NSString).pathExtension)
        else { return false }
        let stem = String(path.dropFirst("assets/gday-preview-".count)) as NSString
        return UUID(uuidString: stem.deletingPathExtension) != nil
    }
    static func writePreview(_ reference: NotesImageReference, png: Data, jpeg: Data?, directory: URL) throws -> String
    {
        var index = try readPreviewIndex(directory)
        let originalPaths = Set(index.files.keys).union([reference.originalPath])
        var path = index.files[reference.originalPath]
        if path == nil, isManagedPreview(reference.displayPath), !originalPaths.contains(reference.displayPath),
            !index.files.values.contains(reference.displayPath)
        {
            path = reference.displayPath
        }
        let useJPEG =
            path.map { ($0 as NSString).pathExtension == "jpg" } ?? (jpeg.map { $0.count < png.count } ?? false)
        guard !useJPEG || jpeg != nil else {
            throw MeetingError.message(
                "The original image now contains transparency. Use Original Size to keep its transparency.")
        }
        let bytes = useJPEG ? jpeg! : png
        if let existing = path {
            guard isManagedPreview(existing), !originalPaths.contains(existing) else {
                throw MeetingError.message("The image preview index contains an invalid path.")
            }
            let target = try NotesAssets.safeURL(relativePath: existing, directory: directory)
            if (try? Data(contentsOf: target, options: .mappedIfSafe)) != bytes {
                try bytes.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
        }
        else {
            path = try write(
                bytes, filename: "gday-preview-\(UUID().uuidString)." + (useJPEG ? "jpg" : "png"), directory: directory)
        }
        let result = path!
        if isManagedPreview(reference.displayPath), reference.displayPath != result,
            !originalPaths.contains(reference.displayPath)
        {
            index.obsolete.insert(reference.displayPath)
        }
        index.files[reference.originalPath] = result
        index.originalVersions[reference.originalPath] = try originalVersion(
            reference.originalPath, directory: directory)
        try savePreviewIndex(index, directory: directory)
        return result
    }
    /// Imported notes may carry several historical previews for the same original.
    /// Only app-managed preview references are normalized; missing unmanaged images stay literal.
    static func canonicalizedNotes(in markdown: String, directory: URL) throws -> String {
        var document = NotesDocument(markdown)
        let references = NotesImageReference.parse(in: document.text)
        for reference in references.reversed() where isManagedPreview(reference.displayPath) {
            let largest = references.filter { $0.originalPath == reference.originalPath }.compactMap(\.width).max()
            guard let original = try? NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory),
                FileManager.default.fileExists(atPath: original.path)
            else { continue }
            let desired = try resized(reference, width: reference.width, directory: directory, previewWidth: largest)
            if desired.markdown != reference.markdown {
                document.replace(reference.range, with: desired.markdown, clock: nil)
            }
        }
        return document.markdown
    }
    /// Prepare restored or imported references before notes are saved or exported.
    static func ensurePreviews(in markdown: String, directory: URL) throws {
        let references = NotesImageReference.parse(in: NotesDocument(markdown).text)
        let groups = Dictionary(grouping: references.filter { isManagedPreview($0.displayPath) }, by: \.originalPath)
        for (_, values) in groups {
            guard let reference = values.first, let largest = values.compactMap(\.width).max() else { continue }
            guard let original = try? NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory),
                FileManager.default.fileExists(atPath: original.path)
            else { continue }
            let metadata = try info(at: original)
            let expected = min(metadata.pixelWidth, Int((largest * 2).rounded()))
            let display = try NotesAssets.safeURL(relativePath: reference.displayPath, directory: directory)
            let index = try readPreviewIndex(directory)
            let version = try originalVersion(reference.originalPath, directory: directory)
            if let current = try? info(at: display), current.pixelWidth == expected,
                index.originalVersions[reference.originalPath] == version,
                index.files[reference.originalPath] == reference.displayPath
            {
                continue
            }
            _ = try makePreview(reference, width: largest, directory: directory)
        }
    }
    /// Run only after the Markdown write succeeds; never remove an original.
    static func cleanupManagedPreviews(in markdown: String, directory: URL) throws {
        let retained = try NotesImageClipboard.retainedMarkdown(directory: directory, markdown: markdown)
        let references = Set(NotesAssets.tokens(in: retained).map(\.path))
        var index = try readPreviewIndex(directory)
        let previousObsolete = index.obsolete
        let originals = Set(index.files.keys).union(
            NotesImageReference.parse(in: NotesDocument(retained).text).map(\.originalPath))
        for preview in Set(index.files.values).union(index.obsolete) where isManagedPreview(preview) {
            guard !originals.contains(preview), !references.contains(preview),
                !retained.contains((preview as NSString).lastPathComponent)
            else { continue }
            let file = try NotesAssets.safeURL(relativePath: preview, directory: directory)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            index.obsolete.remove(preview)
        }
        if index.obsolete != previousObsolete { try savePreviewIndex(index, directory: directory) }
    }
}
