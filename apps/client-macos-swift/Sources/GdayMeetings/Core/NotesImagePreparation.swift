import CoreGraphics
import Foundation

struct NotesPreparedImage: Sendable {
    var original: URL
    var size: CGSize
    var image: CGImage
    var version: String
}

/// Serializes preview mutations, including the preview ownership index.
actor NotesImagePreparation {
    static let shared = NotesImagePreparation()
    private var pendingResults: [UUID: URL] = [:]
    func retainResults(_ token: UUID, directory: URL) { pendingResults[token] = directory.standardizedFileURL }
    func releaseResults(_ token: UUID) { pendingResults.removeValue(forKey: token) }
    private func hasPendingResults(_ directory: URL) -> Bool {
        pendingResults.values.contains(directory.standardizedFileURL)
    }
    private var thumbnails: [String: NotesPreparedImage] = [:]
    private var normalized: [URL: [String: NotesImageReference]] = [:]

    func prepare(_ references: [NotesImageReference], width: CGFloat, directory: URL) -> [String: NotesPreparedImage] {
        var result: [String: NotesPreparedImage] = [:]
        for reference in references {
            guard !Task.isCancelled else { return [:] }
            if result[reference.markdown] != nil { continue }
            do {
                let original = try NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory)
                let requestedDisplay = try NotesAssets.safeURL(
                    relativePath: reference.displayPath, directory: directory)
                let display =
                    FileManager.default.fileExists(atPath: requestedDisplay.path) ? requestedDisplay : original
                let originalMetadata = try original.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let displayMetadata = try display.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let version =
                    "\(original.path)@\(originalMetadata.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(originalMetadata.fileSize ?? 0)@\(display.path)@\(displayMetadata.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(displayMetadata.fileSize ?? 0)@\(width)@\(reference.width ?? -1)"
                if let cached = thumbnails[version] {
                    result[reference.markdown] = cached
                    continue
                }
                let info = try NotesImageStore.info(at: original)
                let displayWidth = min(width, reference.width ?? info.naturalSize.width)
                let size = CGSize(
                    width: displayWidth, height: displayWidth * info.naturalSize.height / info.naturalSize.width)
                let image = try NotesImageStore.thumbnail(
                    at: display, maximumPixels: Int(max(size.width, size.height) * 2))
                let prepared = NotesPreparedImage(original: original, size: size, image: image, version: version)
                if thumbnails.count > 64 { thumbnails.removeAll(keepingCapacity: true) }
                thumbnails[version] = prepared
                result[reference.markdown] = prepared
            }
            catch { continue }
        }
        return result
    }

    func resize(_ reference: NotesImageReference, width: Double?, source: String, directory: URL) throws
        -> NotesImageReference
    {
        let largest = NotesImageReference.parse(in: source).filter {
            $0.originalPath == reference.originalPath && $0.range != reference.range
        }.compactMap(\.width).max()
        return try NotesImageStore.resized(reference, width: width, directory: directory, previewWidth: largest)
    }
    func normalize(_ source: String, directory: URL) throws -> [(NotesImageReference, NotesImageReference)] {
        if normalized.count > 32 { normalized.removeAll(keepingCapacity: true) }
        if normalized[directory, default: [:]].count > 256 { normalized[directory] = [:] }
        let references = NotesImageReference.parse(in: source)
        var result: [(NotesImageReference, NotesImageReference)] = []
        for reference in references where reference.width != nil {
            let original = try NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory)
            let metadata = try original.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let version = "@\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(metadata.fileSize ?? 0)"
            let key = reference.markdown + version
            if var cached = normalized[directory]?[key],
                let display = try? NotesAssets.safeURL(relativePath: cached.displayPath, directory: directory),
                FileManager.default.fileExists(atPath: display.path)
            {
                cached.range = reference.range
                result.append((reference, cached))
                continue
            }
            let largest = references.filter { $0.originalPath == reference.originalPath }.compactMap(\.width).max()
            let desired = try NotesImageStore.resized(
                reference, width: reference.width, directory: directory, previewWidth: largest)
            normalized[directory, default: [:]][key] = desired
            normalized[directory, default: [:]][desired.markdown + version] = desired
            result.append((reference, desired))
        }
        return result
    }
    func importImages(urls: [URL], bytes: Data?, directory: URL) throws -> [NotesImageReference] {
        if !urls.isEmpty { return try urls.map { try NotesImageStore.importFile($0, directory: directory) } }
        if let bytes { return [try NotesImageStore.importClipboard(bytes, directory: directory)] }
        return []
    }
    func ensurePreviews(_ text: String, directory: URL) throws {
        try NotesImageStore.ensurePreviews(in: text, directory: directory)
    }
    func cleanupPreviews(_ text: String, directory: URL) throws {
        guard !hasPendingResults(directory) else { return }
        try NotesImageStore.cleanupManagedPreviews(in: text, directory: directory)

    }
    func cleanupSavedIfMatching(_ text: String, directory: URL) throws {
        guard !hasPendingResults(directory) else { return }
        guard let saved = try? String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8),
            saved == text
        else { return }
        try NotesImageClipboard.cleanupSaved(directory: directory, markdown: saved)
    }

}
