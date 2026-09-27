import AppKit
import UniformTypeIdentifiers

@MainActor final class MeetingExportPanel: NSObject {
    private weak var panel: NSSavePanel?
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let types: [UTType] = [
        .json, UTType(filenameExtension: "md") ?? .plainText,
        UTType(importedAs: "org.textbundle.package", conformingTo: .package),
    ]

    init(panel: NSSavePanel) {
        self.panel = panel
        super.init()
        panel.allowedContentTypes = Self.types
        panel.allowsOtherFileTypes = false
        panel.message = "Export as JSON, Markdown, or TextBundle. Referenced images are included; audio files are not."
        if #available(macOS 15, *) {
            panel.showsContentTypes = true
            panel.currentContentType = .json
        }
        else {
            picker.addItems(withTitles: MeetingExportFormat.allCases.map(\.title))
            picker.target = self
            picker.action = #selector(selectFormat)
            picker.setAccessibilityLabel("Export Format")
            let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), picker])
            row.spacing = 8
            row.orientation = .horizontal
            row.frame = NSRect(x: 0, y: 0, width: 300, height: 36)
            panel.accessoryView = row
            panel.allowedContentTypes = [.json]
        }
    }

    @objc private func selectFormat() {
        guard let panel else { return }
        let index = picker.indexOfSelectedItem
        guard MeetingExportFormat.allCases.indices.contains(index) else { return }
        let format = MeetingExportFormat.allCases[index]
        panel.allowedContentTypes = [Self.types[index]]
        panel.nameFieldStringValue =
            (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + format.fileExtension
    }
}
