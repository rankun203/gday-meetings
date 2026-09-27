import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ArchiveNoteImages {
    static let maximumRequestBytes = 20 * 1024 * 1024
    static let maximumImageBytes = 15 * 1024 * 1024
    static let mediaTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "heif": "image/heif", "tif": "image/tiff",
        "tiff": "image/tiff", "bmp": "image/bmp",
    ]

    static func artifacts(notes: String, directory: URL) throws -> [String: Any] {
        var artifacts: [String: Any] = [:]
        var encodedBytes = 0
        for (path, url) in try NotesAssets.referencedFiles(in: notes, directory: directory) {
            guard path.utf8.count <= 255, let mediaType = mediaTypes[url.pathExtension.lowercased()],
                let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
                let actual = CGImageSourceGetType(source),
                let expected = UTType(filenameExtension: url.pathExtension),
                UTType(actual as String)?.conforms(to: expected) == true
            else {
                throw MeetingError.message(
                    "This image format can’t be archived: \(url.lastPathComponent). Export the meeting to keep its original files."
                )
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maximumImageBytes else {
                throw MeetingError.message(
                    "An image is too large for this server archive: \(url.lastPathComponent). Export the meeting to keep its original files."
                )
            }
            encodedBytes += ((size + 2) / 3) * 4
            guard encodedBytes <= maximumRequestBytes else {
                throw MeetingError.message(
                    "The archive’s encoded images exceed the server’s 20 MiB limit. Export the meeting with its images instead."
                )
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            artifacts[path] = [
                "encoding": "base64", "mediaType": mediaType, "data": data.base64EncodedString(),
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "size": data.count,
            ]
        }
        return artifacts
    }

    static func requestData(_ body: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumRequestBytes else {
            throw MeetingError.message(
                "The archive’s text and encoded images exceed the server’s 20 MiB limit. Export the meeting with its images instead."
            )
        }
        return data
    }

    static func importKey(snapshot: Data, audio: [ArchiveAudio]) -> String {
        var hash = SHA256()
        hash.update(data: snapshot)
        for file in audio { hash.update(data: Data("\n\(file.filename):\(file.sha256):\(file.size)".utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
