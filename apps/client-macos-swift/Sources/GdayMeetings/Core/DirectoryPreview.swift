import Foundation

/// Optional production-component fixture. All files are written off the UI actor.
@MainActor enum DirectoryPreview {
    static func populate(store: MeetingStore) {
        let root = store.dataDirectory
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    let marker = root.appendingPathComponent(".directory-fixture-ready")
                    guard !FileManager.default.fileExists(atPath: marker.path) else { return }
                    let personID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
                    let tagID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
                    let encoder = JSONEncoder()
                    for kind in ["people", "tags"] {
                        try FileManager.default.createDirectory(
                            at: root.appendingPathComponent(kind), withIntermediateDirectories: true)
                    }
                    for number in 0..<1200 {
                        var person = Person(name: String(format: "Person %04d", number))
                        var tag = MeetingTag(name: String(format: "Tag %04d", number))
                        if number == 0 {
                            person.id = personID
                            person.name = "Directory Fixture"
                            tag.id = tagID
                            tag.name = "Directory Fixture"
                        }
                        try encoder.encode(person).write(
                            to: root.appendingPathComponent("people/\(person.id.uuidString).json"), options: .atomic)
                        try encoder.encode(tag).write(
                            to: root.appendingPathComponent("tags/\(tag.id.uuidString).json"), options: .atomic)
                    }
                    for number in 0..<320 {
                        var meeting = Meeting(
                            title: String(format: "Directory meeting %04d", number),
                            createdAt: Date(timeIntervalSince1970: 1_600_000_000 - Double(number * 60)))
                        meeting.personIDs = [personID]
                        meeting.tagIDs = [tagID]
                        try MeetingFolderStorage.write(meeting, directory: root)
                    }
                    try Data().write(to: marker, options: .atomic)
                }.value
                store.requestExternalLibraryReload(paths: [], rebuild: true)
                store.refreshDirectoryIndex(rebuild: true)
                store.libraryMonitor?.rebuild()
            }
            catch { store.errorMessage = "Couldn’t prepare directory fixtures. \(error.localizedDescription)" }
        }
    }
}
