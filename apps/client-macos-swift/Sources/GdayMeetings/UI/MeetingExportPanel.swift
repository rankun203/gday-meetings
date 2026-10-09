import AppKit
import UniformTypeIdentifiers

@MainActor final class MeetingExportPanel: NSObject {
    init(panel: NSSavePanel) {
        super.init()
        panel.title = "Export Meeting"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.zip]
        panel.allowsOtherFileTypes = false
        panel.message = "Choose a destination."
    }
}
