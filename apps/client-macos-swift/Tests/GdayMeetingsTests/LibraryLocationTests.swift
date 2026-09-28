import Foundation
import Testing

@testable import GdayMeetings

struct LibraryLocationTests {
    @Test func resolvesDataFolderWithoutCreatingIt() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let location = LibraryLocation.directory(home: home)
        #expect(location.path == home.path + "/.local/share/com.gdaymeetings.macos")
        #expect(!FileManager.default.fileExists(atPath: location.path))
    }
}
