import Foundation
import Testing

@testable import GdayMeetings

struct VoicePreparationFailureTests {
    @Test func resolvesRecordingAndExampleToSameMeetingTitle() {
        let meeting = UUID()
        let example = VoiceExample(
            meetingID: meeting, speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: "synthetic", start: 1, end: 4)
        let page = TaskFailurePage(
            failures: ["recording-\(meeting)": "Recording error", example.id.uuidString: "Example error"], offset: 0)
        let rows = VoicePreparationFailure.resolve(
            page: page, examples: [example], titles: [meeting: "Synthetic meeting"])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.meetingID == meeting && $0.title == "Synthetic meeting" })
    }

    @Test func missingContextPreservesFailureAndBoundsResolution() {
        let failures = Dictionary(uniqueKeysWithValues: (0..<108).map { ("missing-\($0)", "Synthetic error") })
        let rows = VoicePreparationFailure.resolve(
            page: TaskFailurePage(failures: failures, offset: 100), examples: [], titles: [:])
        #expect(rows.count == 8)
        #expect(
            rows.allSatisfy { $0.meetingID == nil && $0.title == "Voice Example" && $0.message == "Synthetic error" })
        let missing = UUID()
        let recording = VoicePreparationFailure.resolve(
            page: TaskFailurePage(failures: ["recording-\(missing)": "Unavailable"], offset: 0),
            examples: [], titles: [:])
        #expect(recording.first?.meetingID == missing)
        #expect(recording.first?.title == "Recording")
    }

    @Test func indexedTitlesResolveWithoutLoadingMeetingsAndOnlyForVisiblePage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let visible = Meeting(title: "Synthetic indexed recording")
        let next = Meeting(title: "Synthetic later recording")
        for meeting in [visible, next] { try MeetingFolderStorage.write(meeting, directory: root) }
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let examples = (0..<21).map { position in
            var example = VoiceExample(
                meetingID: position < 20 ? visible.id : next.id, speakerID: UUID(), source: "system",
                audioFile: "system.wav", audioRevision: "synthetic", start: 1, end: 4)
            example.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", position))!
            return example
        }
        let failures = Dictionary(uniqueKeysWithValues: examples.map { ($0.id.uuidString, "Synthetic error") })
        let page = TaskFailurePage(failures: failures, offset: 0)
        // Empty loaded titles reproduce a source outside the retained meeting page.
        let rows = VoicePreparationFailure.resolve(page: page, examples: examples, titles: [:])
        let titles = await VoicePreparationFailure.loadTitles(for: rows, index: index)
        #expect(titles == [visible.id: visible.title])
        #expect(titles[next.id] == nil)
        let recording = VoicePreparationFailure.resolve(
            page: TaskFailurePage(failures: ["recording-\(visible.id)": "Synthetic error"], offset: 0),
            examples: [], titles: [:])
        #expect(recording.first?.title == "Recording")
        #expect(await VoicePreparationFailure.loadTitles(for: recording, index: index) == [visible.id: visible.title])
        let renamed = VoicePreparationFailure.resolve(
            page: TaskFailurePage(failures: ["recording-\(visible.id)": "Synthetic error"], offset: 0),
            examples: [], titles: [visible.id: "Renamed synthetic recording"])
        #expect(await VoicePreparationFailure.loadTitles(for: renamed, index: index).isEmpty)

    }

    @Test func loadedTitleWinsOverCachedIndex() throws {
        let meeting = UUID()
        let rows = VoicePreparationFailure.resolve(
            page: TaskFailurePage(failures: ["recording-\(meeting)": "Synthetic error"], offset: 0),
            examples: [], titles: [meeting: "Renamed synthetic recording"])
        let row = try #require(rows.first)
        #expect(row.displayTitle(indexTitles: [meeting: "Older indexed title"]) == "Renamed synthetic recording")
    }

}
