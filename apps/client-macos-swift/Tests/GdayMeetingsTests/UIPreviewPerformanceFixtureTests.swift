import Foundation
import Testing

@testable import GdayMeetings

struct UIPreviewPerformanceFixtureTests {
    @Test func librarySizeRequiresAnExplicitSupportedScale() {
        #expect(UIPreviewPerformanceFixtures.requestedLibrarySize(arguments: [], bundleValue: nil) == nil)
        #expect(UIPreviewPerformanceFixtures.requestedLibrarySize(arguments: [], bundleValue: 10_000) == 10_000)
        #expect(
            UIPreviewPerformanceFixtures.requestedLibrarySize(
                arguments: ["--synthetic-library-size=1000"], bundleValue: 10_000) == 1_000)
        #expect(
            UIPreviewPerformanceFixtures.requestedLibrarySize(
                arguments: ["--synthetic-library-size=1000000"], bundleValue: nil) == nil)
    }

    @Test func generatedMeetingsAreReadableSearchableAndContainNoAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await UIPreviewPerformanceFixtures.generate(count: 3, directory: directory)
        let index = try LibraryIndex(directory: directory)
        try index.rebuild()
        let entries = try index.page(limit: 20)
        #expect(entries.count == 3)
        #expect(try index.searchPage(query: "Synthetic library passage").total == 3)
        for entry in entries {
            let meeting = try MeetingFolderStorage.read(id: entry.id, directory: directory)
            #expect(meeting.audioFiles.isEmpty)
            #expect(meeting.transcript.count == 1)
            #expect(meeting.notes == "Synthetic notes for library scrolling and search.")
            #expect(meeting.summary.hasPrefix("### Review item"))
        }
    }
}
