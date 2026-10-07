import Foundation

/// Read-only provenance for one meeting. Receipt files prove that analysis was
/// saved, but do not by themselves prove that its labels became the transcript.
struct SpeakerLabelingHistory: Sendable {
    struct Entry: Identifiable, Sendable {
        var id: String
        var date: Date
        var providerName: String?
        var modelRevision: String?
        var status: String
        var detail: String?
        var taskID: UUID?
        var resultID: UUID?
    }
    var entries: [Entry]
    var warning: String?

    /// Work and memory are bounded, even if a folder contains corrupt or huge receipts.
    static func load(
        directory: URL, tasks: [ManagedTaskRecord], currentSourceID: UUID? = nil,
        currentLabelingResultID: UUID? = nil
    ) async -> Self {
        let rows = tasks.filter { $0.kind == .diarization }.map { task in
            Entry(
                id: "task-\(task.id)", date: task.createdAt, providerName: task.providerName,
                modelRevision: nil, status: status(task.state), detail: task.errorMessage ?? task.progress,
                taskID: task.id, resultID: task.speakerLabelingResultID)
        }
        return await Task.detached(priority: .utility) {
            read(directory: directory, rows: rows, currentSourceID: currentLabelingResultID ?? currentSourceID)
        }.value
    }

    private struct Receipt: Decodable {
        var version: Int
        var id: UUID
        var generatedAt: Date
        var modelRevision: String
    }

    private static func read(directory: URL, rows: [Entry], currentSourceID: UUID?) -> Self {
        var entries = rows
        var incomplete = false
        var seen = Set<UUID>()
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        else { return Self(entries: rows, warning: "Couldn’t read saved speaker-labeling results.") }
        var visited = 0
        var receiptCount = 0
        var remainingBytes = 32 * 1024 * 1024
        for case let url as URL in enumerator {
            visited += 1
            guard !Task.isCancelled else { break }
            if visited > 10_000 || receiptCount >= 500 {
                incomplete = true
                break
            }
            guard url.lastPathComponent.hasPrefix("speaker-labels-"), url.pathExtension == "json" else { continue }
            receiptCount += 1
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                    let size = values.fileSize, size <= 8 * 1024 * 1024, size <= remainingBytes
                else {
                    incomplete = true
                    continue
                }
                remainingBytes -= size
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: size + 1) ?? Data()
                guard data.count == size else {
                    incomplete = true
                    continue
                }
                let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                guard receipt.version == 1 else {
                    incomplete = true
                    continue
                }
                guard seen.insert(receipt.id).inserted else { continue }
                if let index = entries.firstIndex(where: { $0.resultID == receipt.id }) {
                    entries[index].resultID = receipt.id
                    entries[index].modelRevision = receipt.modelRevision
                    if receipt.id == currentSourceID { entries[index].status = "Current labels" }
                    continue
                }
                entries.append(
                    Entry(
                        id: "result-\(receipt.id)", date: receipt.generatedAt, providerName: "Community-1",
                        modelRevision: receipt.modelRevision,
                        status: receipt.id == currentSourceID ? "Current labels" : "Saved analysis",
                        detail: receipt.id == currentSourceID
                            ? nil : "This result was saved. Its application status wasn’t recorded.",
                        taskID: nil, resultID: receipt.id))
            }
            catch { incomplete = true }
        }
        entries.sort { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        return Self(
            entries: entries,
            warning: incomplete ? "Some saved results couldn’t be read or exceeded the history limits." : nil)
    }

    private static func status(_ state: ManagedTaskState) -> String {
        switch state {
        case .queued: "Queued"
        case .running: "Running"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
