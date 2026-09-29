import Foundation
import Testing

@testable import GdayMeetings

struct AgentGuideTests {
    @Test func generatedGuideContainsCommandsAndAuthoritativeSwiftFiles() {
        let directory = URL(fileURLWithPath: "/tmp/Synthetic meeting library")
        let guide = AgentGuides.contents(directory: directory)
        #expect(guide.hasPrefix("---\n"))
        for filename in ["metadata.json", "notes.md", "transcript.json", "summary.md", "content.json"] {
            #expect(guide.contains(filename))
        }
        #expect(guide.contains("2001-01-01"))
        #expect(guide.contains(AgentGuides.command(directory: directory, claude: false)))
        #expect(guide.contains(AgentGuides.command(directory: directory, claude: true)))
        #expect(guide.contains("This Swift library has no `recordings/index.md`"))
        #expect(guide.contains("transcript-revisions.json"))
        #expect(guide.contains("live-transcript.json"))
        #expect(guide.contains("Keep the last line for each event ID"))
        #expect(guide.contains("separate task stores"))
        #expect(guide.contains("speakerID"))
        #expect(guide.contains("978307200"))
        #expect(guide.contains("rg --files meetings -g metadata.json"))
        #expect(!guide.contains("### Example:"))
        #expect(!guide.contains("secrets.json"))
    }

    @Test func exclusiveCreationPreservesCustomGuideAndReadsCurrentDiskContent() throws {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try AgentGuides.ensure(directory: folder))
        #expect(try !AgentGuides.ensure(directory: folder))
        let custom = "---\ntitle: Custom instructions\n---\n\nKeep these instructions.\n"
        let file = folder.appendingPathComponent("AGENTS.md")
        try Data(custom.utf8).write(to: file)
        #expect(try !AgentGuides.ensure(directory: folder, allowCreate: false))
        #expect(try AgentGuides.read(directory: folder) == custom)
        let edited = custom + "\nA new instruction.\n"
        try Data(edited.utf8).write(to: file)
        #expect(try AgentGuides.read(directory: folder) == edited)
        #expect(try Data(contentsOf: file) == Data(edited.utf8))
    }

    @Test func existingGuideSymlinkIsPreservedAndDirectoryIsRejected() throws {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("custom.md")
        let bytes = Data("---\ntitle: Custom guide\n---\n\nRead-only analysis.\n".utf8)
        try bytes.write(to: target)
        let link = folder.appendingPathComponent("AGENTS.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try !AgentGuides.ensure(directory: folder))
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try Data(contentsOf: target) == bytes)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        #expect(throws: ServiceError.self) { try AgentGuides.ensure(directory: folder) }
    }

    @Test func shellQuotingPreservesSpacesQuotesAndShellSyntax() throws {
        let path = "/tmp/Meeting 'notes' $HOME `whoami` $(echo unexpected)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", "printf %s " + AgentGuides.shellQuote(path)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let value = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: value, as: UTF8.self) == path)
        let folder = URL(fileURLWithPath: path)
        #expect(
            AgentGuides.command(directory: folder, claude: false) == "cd -- " + AgentGuides.shellQuote(path)
                + " && codex")
        #expect(
            AgentGuides.command(directory: folder, claude: true) == "cd -- " + AgentGuides.shellQuote(path)
                + " && claude")
    }

    @Test func commandFencesCannotBeClosedByFolderBackticks() {
        let command = "cd '/tmp/```\n````\nfolder' && codex"
        let document = NotesReadingDocument(AgentGuides.fenced(command))
        let code = document.blocks.compactMap { block -> String? in
            if case .code(let value) = block.content { return value }
            return nil
        }
        #expect(code == [command])
    }

    @Test func displayHidesOnlyCompleteInitialFrontmatter() {
        #expect(AgentGuides.displayBody("---\ntitle: Guide\n---\n\n# Saved body\n\nText") == "# Saved body\n\nText")
        #expect(AgentGuides.displayBody("# Custom guide\n\n---\n\nText") == "# Custom guide\n\n---\n\nText")
        #expect(AgentGuides.displayBody("---\nUnclosed metadata") == "---\nUnclosed metadata")
        #expect(AgentGuides.displayBody("---\ntitle: Guide\n...\nBody") == "Body")
    }

    @MainActor @Test func startupCreatesOnlyRootGuideAndMeetingHistoryRemainsIntact() throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingStore(dataDirectory: folder)
        let root = folder.appendingPathComponent("AGENTS.md")
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(try AgentGuides.read(directory: folder).contains(AgentGuides.command(directory: folder, claude: false)))
        let id = store.createMeeting(title: "Synthetic meeting")
        var meeting = try #require(store.meeting(id: id))
        meeting.chat = [.init(role: "user", content: "Synthetic earlier question")]
        #expect(store.updateMeeting(meeting))
        #expect(
            !FileManager.default.fileExists(atPath: store.directory(for: id).appendingPathComponent("AGENTS.md").path))
        #expect(store.meeting(id: id)?.chat == meeting.chat)
        let custom = "---\ntitle: Existing guide\n---\n\nPreserve this guide.\n"
        try Data(custom.utf8).write(to: root)
        _ = MeetingStore(dataDirectory: folder)
        #expect(try AgentGuides.read(directory: folder) == custom)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentGuide-\(UUID())")
    }
}
