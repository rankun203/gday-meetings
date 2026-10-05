import AppKit
import UniformTypeIdentifiers

@MainActor final class MeetingExportPanel: NSObject {
    private static let types: [UTType] = [
        .json, UTType(filenameExtension: "md") ?? .plainText,
        UTType(importedAs: "org.textbundle.package", conformingTo: .package),
    ]

    init(panel: NSSavePanel) {
        super.init()
        panel.allowedContentTypes = Self.types
        panel.allowsOtherFileTypes = false
        panel.message = "Export as JSON, Markdown, or TextBundle. Referenced images are included; audio files are not."
        panel.showsContentTypes = true
        panel.currentContentType = .json
    }
}
