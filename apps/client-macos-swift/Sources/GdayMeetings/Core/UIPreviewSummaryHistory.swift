import Foundation

extension UIPreview {
    @MainActor static func seedSummaryHistory(store: MeetingStore, meeting: Meeting) throws {
        let folder = store.directory(for: meeting.id)
        let firstDate = meeting.createdAt.addingTimeInterval(-3600)
        let first = SummaryGeneration(
            id: UUID(), generation: 1, createdAt: firstDate,
            providerName: "Preview Provider", model: "Preview Model",
            messages: [], bodies: [], filePaths: [], extractTodos: false,
            result: """
                ### Key points

                - Review the draft schedule.
                - Confirm the next review date.

                ### Action items

                - [ ] Update the planning notes.
                """, completedAt: firstDate.addingTimeInterval(10))
        let second = SummaryGeneration(
            id: UUID(), generation: 2, createdAt: meeting.createdAt,
            providerName: "Preview Provider", model: "Preview Model",
            messages: [], bodies: [], filePaths: [], extractTodos: false,
            result: meeting.summary, completedAt: meeting.createdAt.addingTimeInterval(10))
        let history = SummaryHistory(nextGeneration: 3, currentID: second.id, entries: [first.entry, second.entry])
        let encoder = JSONEncoder()
        for generation in [first, second] {
            try encoder.encode(generation).write(
                to: folder.appendingPathComponent(SummaryGeneration.filename(generation.id)), options: .atomic)
        }
        try encoder.encode(history).write(to: folder.appendingPathComponent(SummaryHistory.filename), options: .atomic)
    }
}
