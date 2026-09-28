import Foundation

enum LibraryLocation {
    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/share/com.gdaymeetings.macos", isDirectory: true)
    }

}
