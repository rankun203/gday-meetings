import AppKit

enum LogFollow {
    @MainActor
    static func open() async throws {
        let workspace = NSWorkspace.shared
        guard let application = workspace.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            throw ServiceError("Console could not be found in Applications → Utilities.")
        }
        _ = try await workspace.openApplication(at: application, configuration: .init())
    }
}
