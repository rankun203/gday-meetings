import Foundation

/// Copy referenced image bytes between meetings without trusting pasteboard paths.
enum NotesImageClipboard {
    static func copyAssets(in markdown: String, from source: URL, to destination: URL) throws -> String {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return markdown }
        let files = try NotesAssets.referencedFiles(in: markdown, directory: source)
        var paths: [String: String] = [:]
        for (path, url) in files.sorted(by: { $0.key < $1.key }) {
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            var filename = url.lastPathComponent
            if NotesImageStore.isManagedPreview(path),
                let existing = try? NotesAssets.safeURL(relativePath: path, directory: destination),
                let previous = try? Data(contentsOf: existing), previous != bytes
            {
                filename = "gday-preview-\(UUID().uuidString)." + url.pathExtension
            }
            paths[path] = try NotesImageStore.write(bytes, filename: filename, directory: destination)
        }
        return NotesAssets.rewritingReferences(in: markdown, paths: paths)
    }
    /// Conflict copies remain recoverable, including their image assets.
    static func retainedMarkdown(directory: URL, markdown: String) throws -> String {
        var retained = markdown
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for file in files
        where file.lastPathComponent == "summary.md"
            || (file.lastPathComponent.hasPrefix("notes (changed on disk") && file.pathExtension == "md")
            || (file.lastPathComponent.hasPrefix("summary (changed on disk") && file.pathExtension == "md")
        {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true, properties.isRegularFile == true else { continue }
            retained += "\n" + (try String(contentsOf: file, encoding: .utf8))
        }
        return retained
    }
    static func cleanupSaved(directory: URL, markdown: String) throws {
        try NotesImageStore.cleanup(
            directory: directory, markdown: retainedMarkdown(directory: directory, markdown: markdown))
    }
}
