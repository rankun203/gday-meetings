import Foundation

extension UIPreview {
    enum SummaryHistoryScenario: String, CaseIterable {
        case empty, current, error
        case selectionError = "selection-error"

        static func requested(arguments: [String]) -> Self? {
            arguments.lazy.compactMap { argument in
                guard argument.hasPrefix("--synthetic-summary-history=") else { return nil }
                return Self(rawValue: String(argument.dropFirst("--synthetic-summary-history=".count)))
            }.first
        }
    }

    /// Change only the temporary synthetic meeting after its normal history is seeded.
    @MainActor static func configureSummaryHistoryScenario(
        store: MeetingStore, meetingID: UUID,
        scenario: SummaryHistoryScenario? = SummaryHistoryScenario.requested(
            arguments: ProcessInfo.processInfo.arguments)
    ) async throws {
        guard let scenario else { return }
        let folder = store.directory(for: meetingID)
        let history = try SummaryHistory.read(at: folder)
        switch scenario {
        case .empty, .current:
            for entry in history.entries {
                try FileManager.default.removeItem(
                    at: folder.appendingPathComponent(SummaryGeneration.filename(entry.id)))
            }
            try FileManager.default.removeItem(at: folder.appendingPathComponent(SummaryHistory.filename))
            if scenario == .empty, var meeting = store.meeting(id: meetingID) {
                meeting.summary = ""
                guard await store.updateMeeting(meeting) else {
                    throw ServiceError("Couldn’t prepare the empty summary history preview.")
                }
            }
        case .error:
            try Data("Invalid synthetic history".utf8).write(
                to: folder.appendingPathComponent(SummaryHistory.filename), options: .atomic)
        case .selectionError:
            for entry in history.entries {
                try Data("Invalid synthetic summary".utf8).write(
                    to: folder.appendingPathComponent(SummaryGeneration.filename(entry.id)), options: .atomic)
            }
        }
    }
}
