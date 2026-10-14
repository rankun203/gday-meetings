import CryptoKit
import Foundation

struct SummaryHistory: Codable {
    var version = 1
    var nextGeneration = 1
    var currentID: UUID?
    var entries: [Entry] = []

    struct Entry: Codable, Identifiable {
        var id: UUID
        var generation: Int
        var taskID: UUID?
        var createdAt: Date
        var acceptedAt: Date?
        var prepared: Bool? = true
        var completedAt: Date?
        var providerName: String
    }

    static let filename = "summary-history.json"
    static func read(at directory: URL) throws -> Self {
        let bytes = try bytes(filename, at: directory)
        let value = try bytes.map { try JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        guard value.version == 1 else {
            throw ServiceError("The saved summary history uses an unsupported format.")
        }
        return value
    }

    static func bytes(_ name: String, at directory: URL) throws -> Data? {
        try PrivateTranscriptFile.validatePath(name: name, at: directory)
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    static func generation(taskID: UUID, at directory: URL) throws -> SummaryGeneration? {
        guard let entry = try read(at: directory).entries.first(where: { $0.taskID == taskID }) else { return nil }
        guard try bytes(SummaryGeneration.filename(entry.id), at: directory) != nil else {
            guard entry.prepared == false, entry.completedAt == nil else {
                throw ServiceError("The saved summary version is missing.")
            }
            return nil
        }
        return try SummaryGeneration.read(id: entry.id, at: directory)
    }
}

struct SummaryGeneration: Codable, Identifiable {
    var version = 1
    var id: UUID
    var generation: Int
    var taskID: UUID?
    var createdAt: Date
    var acceptedAt: Date?
    var providerID: UUID?
    var providerName: String
    var model: String?
    var endpoint: String?
    var endpointFingerprint: String?
    var messages: [LLMMessage]
    var bodies: [String]
    var filePaths: [String]
    var extractTodos: Bool
    var result: String?
    var completedAt: Date?

    static func endpointFingerprint(_ endpoint: String) -> String {
        SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func endpointDescription(_ endpoint: String) -> String? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }

    static func filename(_ id: UUID) -> String { "summary-generation-\(id.uuidString).json" }
    static func read(id: UUID, at directory: URL) throws -> Self {
        guard let bytes = try SummaryHistory.bytes(filename(id), at: directory) else {
            throw ServiceError("The saved summary version is missing.")
        }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.version == 1, value.id == id else {
            throw ServiceError("The saved summary version uses an unsupported format.")
        }
        return value
    }

    var entry: SummaryHistory.Entry {
        .init(
            id: id, generation: generation, taskID: taskID, createdAt: createdAt, acceptedAt: acceptedAt,
            completedAt: completedAt, providerName: providerName)
    }
}

extension MeetingStore {
    func reserveSummaryGeneration(task: ManagedTaskRecord) async throws {
        let saved = await enqueueCanonical { [self] in
            do {
                guard libraryWritable, meeting(id: task.meetingID) != nil,
                    !deletingMeetingIDs.contains(task.meetingID)
                else { return false }
                var history = try SummaryHistory.read(at: directory(for: task.meetingID))
                if history.entries.contains(where: { $0.taskID == task.id }) { return true }
                history.entries.append(
                    .init(
                        id: UUID(), generation: history.nextGeneration, taskID: task.id,
                        createdAt: Date(), acceptedAt: task.createdAt, prepared: false,
                        providerName: task.providerName ?? "Summary"))
                history.nextGeneration += 1
                return await performCanonicalSave(
                    artifacts: try summaryArtifacts(history: history, generations: [], meetingID: task.meetingID))
            }
            catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        guard saved else { throw ServiceError(errorMessage ?? "Couldn’t save the summary request.") }
    }

    func hasCompletedSummary(taskID: UUID, meetingID: UUID) throws -> Bool {
        try SummaryHistory.generation(taskID: taskID, at: directory(for: meetingID))?.result != nil
    }

    func prepareSummaryRequest(task: ManagedTaskRecord, meetingSnapshot: Meeting? = nil) async throws
        -> SummaryGeneration
    {
        try await reserveSummaryGeneration(task: task)
        if let existing = try SummaryHistory.generation(taskID: task.id, at: directory(for: task.meetingID)) {
            return existing
        }
        guard let meeting = meetingSnapshot ?? meeting(id: task.meetingID), meeting.id == task.meetingID else {
            throw ServiceError("This meeting no longer exists.")
        }
        guard !meeting.transcript.isEmpty || !meeting.notes.isEmpty else {
            throw ServiceError("Add notes or transcribe the meeting before generating a summary.")
        }
        let provider = try summaryProvider(providerID: task.providerID).provider
        let messages = try await summaryMessages(
            provider: provider, meeting: meeting, instructions: task.summaryInstructions)
        var bodies = summaryDataBodies(meeting, messages: messages)
        if task.summaryInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            bodies.append("User Instructions")
        }
        return try await prepareSummaryGeneration(
            meetingID: meeting.id, taskID: task.id, provider: provider, messages: messages,
            bodies: bodies, filePaths: summaryDataFilePaths(meeting, messages: messages),
            extractTodos: task.pipelineID == nil && (task.extractTodosAfterSummary ?? settings.autoExtractTodos),
            acceptedAt: task.createdAt)
    }

    func prepareSummaryGeneration(
        meetingID: UUID, taskID: UUID?, provider: ServiceProvider, messages: [LLMMessage],
        bodies: [String], filePaths: [String], extractTodos: Bool, acceptedAt: Date? = nil
    ) async throws -> SummaryGeneration {
        var prepared: SummaryGeneration?
        let saved = await enqueueCanonical { [self] in
            do {
                guard libraryWritable, !deletingMeetingIDs.contains(meetingID), meeting(id: meetingID) != nil else {
                    return false
                }
                let folder = directory(for: meetingID)
                var history = try SummaryHistory.read(at: folder)
                if let taskID, let existing = try SummaryHistory.generation(taskID: taskID, at: folder) {
                    prepared = existing
                    return true
                }
                let reservation = taskID.flatMap { taskID in history.entries.first { $0.taskID == taskID } }
                let value = SummaryGeneration(
                    id: reservation?.id ?? UUID(), generation: reservation?.generation ?? history.nextGeneration,
                    taskID: taskID, createdAt: Date(),
                    acceptedAt: acceptedAt,
                    providerID: provider.id, providerName: provider.name, model: provider.model,
                    endpoint: SummaryGeneration.endpointDescription(provider.endpoint),
                    endpointFingerprint: SummaryGeneration.endpointFingerprint(provider.endpoint),
                    messages: messages, bodies: bodies, filePaths: filePaths, extractTodos: extractTodos)
                if let index = history.entries.firstIndex(where: { $0.id == value.id }) {
                    history.entries[index] = value.entry
                }
                else {
                    history.nextGeneration += 1
                    history.entries.append(value.entry)
                }
                let artifacts = try summaryArtifacts(history: history, generations: [value], meetingID: meetingID)
                guard await performCanonicalSave(artifacts: artifacts) else { return false }
                prepared = value
                return true
            }
            catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        guard saved, let prepared else { throw ServiceError(errorMessage ?? "Couldn’t save the summary request.") }
        return prepared
    }

    private func summaryArtifacts(
        history: SummaryHistory, generations: [SummaryGeneration], meetingID: UUID
    ) throws -> [CanonicalMeetingArtifact] {
        let folder = directory(for: meetingID)
        let values =
            [(SummaryHistory.filename, try JSONEncoder().encode(history))]
            + (try generations.map { (SummaryGeneration.filename($0.id), try JSONEncoder().encode($0)) })
        return try values.map { name, data in
            .init(meetingID: meetingID, name: name, data: data, previous: try SummaryHistory.bytes(name, at: folder))
        }
    }

    @discardableResult
    func restoreSummaryGeneration(id: UUID, meetingID: UUID) async -> Bool {
        await enqueueCanonical { [self] in
            do {
                guard libraryWritable, !deletingMeetingIDs.contains(meetingID),
                    let index = meetings.firstIndex(where: { $0.id == meetingID })
                else { return false }
                let folder = directory(for: meetingID)
                var history = try SummaryHistory.read(at: folder)
                guard history.entries.contains(where: { $0.id == id && $0.completedAt != nil }) else { return false }
                let selected = try SummaryGeneration.read(id: id, at: folder)
                guard let result = selected.result else { return false }
                var artifacts: [SummaryGeneration] = []
                let current = try history.currentID.map { try SummaryGeneration.read(id: $0, at: folder) }
                if !meetings[index].summary.isEmpty, current?.result != meetings[index].summary {
                    let preserved = SummaryGeneration(
                        id: UUID(), generation: 0, createdAt: Date(), providerName: "Edited Summary",
                        messages: [], bodies: [], filePaths: [], extractTodos: false,
                        result: meetings[index].summary, completedAt: Date())
                    history.entries.append(preserved.entry)
                    artifacts.append(preserved)
                }
                history.currentID = id
                let writes = try summaryArtifacts(history: history, generations: artifacts, meetingID: meetingID)
                meetings[index].summary = result
                invalidateExternalMeetingReloads(ids: [meetingID])
                let saved = await performCanonicalSave(artifacts: writes)
                if saved { summaryHistoryRevisions[meetingID, default: 0] += 1 }
                return saved
            }
            catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
    }

    func commitSummaryGeneration(_ request: SummaryGeneration, result: String, meetingID: UUID) async throws {
        let saved = await enqueueCanonical { [self] in
            do {
                guard libraryWritable, !deletingMeetingIDs.contains(meetingID),
                    let index = meetings.firstIndex(where: { $0.id == meetingID })
                else { return false }
                let folder = directory(for: meetingID)
                var history = try SummaryHistory.read(at: folder)
                var generation = try SummaryGeneration.read(id: request.id, at: folder)
                guard generation.result == nil else { return true }
                generation.result = result
                generation.completedAt = Date()
                var artifacts = [generation]
                let newerCompleted = history.entries.contains {
                    $0.completedAt != nil && $0.generation > generation.generation
                }
                var current = meetings[index]
                if !newerCompleted {
                    let selected = try history.currentID.map { try SummaryGeneration.read(id: $0, at: folder) }
                    if !current.summary.isEmpty, selected?.result != current.summary {
                        let preserved = SummaryGeneration(
                            id: UUID(), generation: 0, createdAt: Date(),
                            providerName: selected == nil ? "Existing Summary" : "Edited Summary",
                            messages: [], bodies: [], filePaths: [], extractTodos: false,
                            result: current.summary, completedAt: Date())
                        history.entries.append(preserved.entry)
                        artifacts.append(preserved)
                    }
                    current.summary = result
                    history.currentID = generation.id
                    if generation.extractTodos {
                        let known = Set(current.todos.map { $0.title.lowercased() })
                        current.todos += Self.actionItems(from: result).filter {
                            !known.contains($0.title.lowercased())
                        }
                    }
                }
                if let taskID = generation.taskID {
                    current.completedTaskIDs[BackgroundJob.Kind.summary.rawValue] = taskID
                }
                guard let entry = history.entries.firstIndex(where: { $0.id == generation.id }) else {
                    throw ServiceError("The saved summary request is missing from its history.")
                }
                history.entries[entry] = generation.entry
                let writes = try summaryArtifacts(history: history, generations: artifacts, meetingID: meetingID)
                meetings[index] = current
                invalidateExternalMeetingReloads(ids: [meetingID])
                let saved = await performCanonicalSave(artifacts: writes)
                if saved { summaryHistoryRevisions[meetingID, default: 0] += 1 }
                return saved
            }
            catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        guard saved else { throw ServiceError(errorMessage ?? "Couldn’t save the summary.") }
    }
}
