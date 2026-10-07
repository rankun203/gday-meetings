import Foundation
import Testing

@testable import GdayMeetings

struct SpeakerLabelingHistoryTests {
    private func writeResult(at directory: URL, id: UUID = UUID(), revision: String = "synthetic-r1") throws -> UUID {
        let result = LocalDiarizationResult(id: id, modelRevision: revision, ranges: [], speakers: [])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("speaker-labels-\(id).json"))
        return id
    }

    @Test func includesLegacyResultsAndDeduplicatesOnlyExactTaskBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = try writeResult(at: directory)
        let linked = try writeResult(at: directory)
        var task = ManagedTaskRecord(kind: .diarization, meetingID: UUID(), meetingTitle: "Synthetic meeting")
        task.state = .completed
        task.providerName = "Configured local provider"
        task.speakerLabelingResultID = linked
        let history = await SpeakerLabelingHistory.load(directory: directory, tasks: [task], currentSourceID: legacy)
        #expect(history.entries.count == 2)
        #expect(history.entries.first(where: { $0.taskID == task.id })?.modelRevision == "synthetic-r1")
        #expect(history.entries.first(where: { $0.resultID == legacy })?.status == "Current labels")
        #expect(history.entries.first(where: { $0.taskID == task.id })?.providerName == "Configured local provider")
        #expect(history.warning == nil)
    }

    @Test func completedHistoryShowsResultCoverageInsteadOfStaleProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result = LocalDiarizationResult(modelRevision: "synthetic", ranges: [], speakers: [])
        result.detail = "2 voice groups. 3 seconds of speaker activity need review."
        try JSONEncoder().encode(result).write(
            to: directory.appendingPathComponent("speaker-labels-\(result.id).json"))
        var task = ManagedTaskRecord(kind: .diarization, meetingID: UUID(), meetingTitle: "Synthetic meeting")
        task.state = .completed
        task.progress = "Consolidating speakers…"
        let unbound = await SpeakerLabelingHistory.load(directory: directory, tasks: [task])
        #expect(unbound.entries.first(where: { $0.taskID == task.id })?.detail == nil)
        task.speakerLabelingResultID = result.id
        let current = await SpeakerLabelingHistory.load(
            directory: directory, tasks: [task], currentLabelingResultID: result.id)
        #expect(current.entries.count == 1)
        #expect(current.entries.first?.status == "Current labels")
        #expect(current.entries.first?.detail == result.detail)
    }

    @Test func ambiguousOldTaskAndSavedAnalysisRemainSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resultID = try writeResult(at: directory)
        var task = ManagedTaskRecord(kind: .diarization, meetingID: UUID(), meetingTitle: "Synthetic meeting")
        task.state = .failed
        task.errorMessage = "The transcript could not be saved."
        let history = await SpeakerLabelingHistory.load(directory: directory, tasks: [task])
        #expect(history.entries.count == 2)
        #expect(history.entries.first(where: { $0.resultID == resultID })?.status == "Saved analysis")
        #expect(history.entries.first(where: { $0.taskID == task.id })?.status == "Failed")
        #expect(history.entries.first(where: { $0.taskID == task.id })?.providerName == nil)
    }

    @Test func skipsMalformedAndSymlinkedReceiptsWithoutLosingValidHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeResult(at: directory)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("speaker-labels-bad.json"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("speaker-labels-link.json"),
            withDestinationURL: directory.appendingPathComponent("speaker-labels-bad.json"))
        let history = await SpeakerLabelingHistory.load(directory: directory, tasks: [])
        #expect(history.entries.count == 1)
        #expect(history.warning != nil)
    }
}
