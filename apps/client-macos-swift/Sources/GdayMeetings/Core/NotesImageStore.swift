import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct NotesImageInfo {
    var pixelWidth: Int
    var pixelHeight: Int
    var dpi: Double
    var naturalSize: CGSize {
        CGSize(width: Double(pixelWidth) * 72 / dpi, height: Double(pixelHeight) * 72 / dpi)
    }
}

enum NotesImageStore {
    static func info(at url: URL) throws -> NotesImageInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw MeetingError.message("This file isn’t a supported image.")
        }
        return try info(source)
    }
    private static func info(_ source: CGImageSource) throws -> NotesImageInfo {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.intValue > 0, height.intValue > 0,
            width.doubleValue * height.doubleValue <= 100_000_000
        else {
            throw MeetingError.message("This image is too large or has no readable dimensions.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let dpi =
            (properties[rotated ? kCGImagePropertyDPIHeight : kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return .init(
            pixelWidth: rotated ? height.intValue : width.intValue,
            pixelHeight: rotated ? width.intValue : height.intValue,
            dpi: dpi.isFinite && dpi > 0 ? dpi : 72)
    }
    static func isImage(_ url: URL) -> Bool { (try? info(at: url)) != nil }
    static func importFile(_ source: URL, directory: URL) throws -> NotesImageReference {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        _ = try info(at: source)
        let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
        var filename = normalizedName(source.lastPathComponent)
        if let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
            let identifier = CGImageSourceGetType(imageSource) as String?,
            let type = UTType(identifier), let ext = type.preferredFilenameExtension,
            UTType(filenameExtension: source.pathExtension)?.identifier != identifier
        {
            filename = (filename as NSString).deletingPathExtension + "." + ext
        }
        let path = try write(bytes, filename: filename, directory: directory)
        return .init(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path,
            width: nil, alt: source.deletingPathExtension().lastPathComponent)
    }
    static func importClipboard(_ bytes: Data, directory: URL, date: Date = Date()) throws -> NotesImageReference {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            throw MeetingError.message("The clipboard doesn’t contain a readable image.")
        }
        let metadata = try info(source)
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(metadata.pixelWidth, metadata.pixelHeight),
                ] as CFDictionary)
        else {
            throw MeetingError.message("Couldn’t read the clipboard image.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let png = try encode(image, type: .png, dpi: metadata.dpi)
        let path = try write(png, filename: "pasted-image-\(formatter.string(from: date)).png", directory: directory)
        return .init(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path,
            width: nil, alt: "Pasted image")
    }
    static func normalizedName(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let clean = String(stem.unicodeScalars.filter { allowed.contains($0) })
        let ext = String(
            url.pathExtension.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return (clean.isEmpty ? "image" : clean) + (ext.isEmpty ? "" : "." + ext)
    }
    @discardableResult static func write(_ bytes: Data, filename: String, directory: URL) throws -> String {
        let assets = try NotesAssets.safeURL(relativePath: "assets/placeholder", directory: directory)
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: assets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = normalizedName(filename)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 1
        while true {
            let candidate = suffix == 1 ? name : base + "-\(suffix)" + (ext.isEmpty ? "" : "." + ext)
            let path = "assets/" + candidate
            let target = try NotesAssets.safeURL(relativePath: path, directory: directory)
            if FileManager.default.fileExists(atPath: target.path) {
                if try Data(contentsOf: target, options: .mappedIfSafe) == bytes { return path }
                suffix += 1
                continue
            }
            let temporary = assets.appendingPathComponent(".image-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard
                FileManager.default.createFile(
                    atPath: temporary.path, contents: bytes, attributes: [.posixPermissions: 0o600])
            else {
                throw MeetingError.message("Couldn’t save the image. Check available storage.")
            }
            try FileManager.default.moveItem(at: temporary, to: target)
            return path
        }
    }
    static func thumbnail(at url: URL, maximumPixels: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixels),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw MeetingError.message("Couldn’t display this image.") }
        return image
    }
    static func resized(_ reference: NotesImageReference, width: Double?, directory: URL, previewWidth: Double? = nil)
        throws -> NotesImageReference
    {
        let original = try NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory)
        let metadata = try info(at: original)
        var result = reference
        guard let width, width.isFinite, width >= 1, width <= 100_000,
            abs(width - metadata.naturalSize.width) >= 0.5
        else {
            result.width = nil
            result.displayPath = result.originalPath
            return result
        }
        let rounded = width.rounded()
        result.width = rounded
        if rounded * 2 >= Double(metadata.pixelWidth) {
            result.displayPath = result.originalPath
            return result
        }
        result.displayPath = try makePreview(
            reference, width: max(rounded, previewWidth ?? rounded), directory: directory)
        return result
    }
    static func makePreview(_ reference: NotesImageReference, width: Double, directory: URL) throws -> String {
        let original = try NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory)
        let metadata = try info(at: original)
        let targetPixels = min(Double(metadata.pixelWidth), width * 2)
        let ratio = Double(metadata.pixelHeight) / Double(metadata.pixelWidth)
        let image = try thumbnail(at: original, maximumPixels: Int((targetPixels * max(1, ratio)).rounded()))
        let png = try encode(image, type: .png, dpi: 144)
        let jpeg = !hasTransparency(image) ? try encode(image, type: .jpeg, dpi: 144) : nil
        return try writePreview(reference, png: png, jpeg: jpeg, directory: directory)
    }
    private static func hasTransparency(_ image: CGImage) -> Bool {
        if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return false }
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data
        else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return stride(from: 3, to: image.width * image.height * 4, by: 4).contains { bytes[$0] < 255 }
    }
    private static func encode(_ image: CGImage, type: UTType, dpi: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw MeetingError.message("Couldn’t create an image copy.")
        }
        CGImageDestinationAddImage(
            destination, image,
            [
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
                kCGImageDestinationLossyCompressionQuality: 0.85,
            ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MeetingError.message("Couldn’t save an image copy.")
        }
        return output as Data
    }
    /// Call only after the editor's undo session ends and its notes saved successfully.
    /// A malformed reference conservatively keeps assets instead of risking data loss.
    static func cleanup(directory: URL, markdown: String, trash: ((URL) throws -> Void)? = nil) throws {
        let assets = try NotesAssets.safeURL(relativePath: "assets/placeholder", directory: directory)
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: assets.path) else { return }
        let referenced = Set(NotesAssets.tokens(in: markdown).map(\.path))
        for token in referenced { _ = try NotesAssets.safeURL(relativePath: token, directory: directory) }
        guard
            let files = FileManager.default.enumerator(
                at: assets, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return }
        for case let file as URL in files {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else {
                files.skipDescendants()
                continue
            }
            guard properties.isRegularFile == true else { continue }
            let relative = "assets/" + String(file.path.dropFirst(assets.path.count + 1))
            if referenced.contains(relative) || markdown.contains(file.lastPathComponent)
                || markdown.contains(NotesAssets.encodedPath(file.lastPathComponent))
            {
                continue
            }
            if let trash {
                try trash(file)
            }
            else {
                _ = try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            }
        }
    }
}
