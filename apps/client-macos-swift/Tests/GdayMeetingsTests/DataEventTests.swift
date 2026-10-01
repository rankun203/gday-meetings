import Foundation
import Testing

@testable import GdayMeetings

struct DataEventTests {
    @Test func successfulProviderResultContainsMeasuredReceipt() async throws {
        let before = Date()
        let result = try await ProviderDataOperation.perform(
            targetID: UUID(), target: "Example Provider",
            endpoint: "https://processing.example.invalid/v1?token=synthetic",
            bodies: ["microphone.opus", "notes.md"], purpose: "Transcription"
        ) {
            ProviderDataOperation.metrics?.record(sent: 120, received: 30)
            ProviderDataOperation.metrics?.record(sent: 10, received: 5)
            return "Synthetic response"
        }
        func receipt<R: ProviderDataResult>(_ result: R) -> DataFlow { result.dataFlow }
        let flow = receipt(result)
        #expect(result.value == "Synthetic response")
        #expect(flow.location == .remote)
        #expect(flow.targetName == "Example Provider")
        #expect(flow.domain == "processing.example.invalid")
        #expect(flow.bodies == ["microphone.opus", "notes.md"])
        #expect(flow.requestBytes == 130)
        #expect(flow.responseBytes == 35)
        #expect(flow.startedAt >= before)
        #expect(try #require(flow.endedAt) >= flow.startedAt)
        #expect(try #require(flow.duration) >= 0)
        #expect(ProviderDataOperation.metrics == nil)
        let encoded = String(decoding: try JSONEncoder().encode(flow), as: UTF8.self)
        #expect(!encoded.contains("token"))
        #expect(!encoded.contains("Synthetic response"))
    }

    @Test func failedOperationProducesNoSuccessEventAndRestoresMeasurementScope() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let result: ProviderResult<String> = try await ProviderDataOperation.perform(
                targetID: UUID(), target: "Example Provider", endpoint: "https://processing.example.invalid",
                bodies: ["notes.md"], purpose: "Summary"
            ) {
                ProviderDataOperation.metrics?.record(sent: 200, received: 40)
                throw ServiceError("Synthetic failure")
            }
            try DataEventJournal.append(.init(action: .sent, dataFlow: result.dataFlow), directory: directory)
            Issue.record("The operation should have failed")
        }
        catch { #expect(error.localizedDescription.contains("Synthetic failure")) }
        #expect(ProviderDataOperation.metrics == nil)
        #expect(try DataEventJournal.read(directory: directory).isEmpty)
    }

    @Test func nestedMeasurementsRemainSeparateAndUnknownSizesStayUnknown() async throws {
        let result = try await ProviderDataOperation.perform(
            targetID: UUID(), target: "Local Provider", endpoint: "http://127.0.0.1:8080",
            bodies: ["transcript"], purpose: "Summary"
        ) {
            ProviderDataOperation.metrics?.record(sent: 12, received: nil)
            let nested = try await ProviderDataOperation.perform(
                targetID: UUID(), target: "Other Provider", endpoint: "https://other.example.invalid",
                bodies: ["notes.md"], purpose: "Summary"
            ) {
                ProviderDataOperation.metrics?.record(sent: 99, received: 88)
                return true
            }
            #expect(nested.dataFlow.requestBytes == 99)
            #expect(nested.dataFlow.responseBytes == 88)
            ProviderDataOperation.metrics?.record(sent: 3, received: 2)
            return true
        }
        #expect(result.dataFlow.location == .local)
        #expect(result.dataFlow.requestBytes == 15)
        #expect(result.dataFlow.responseBytes == nil)
    }

    @Test func journalPreservesEarlierEventsAcrossInterruptedAppend() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let event = MeetingDataEvent(
            action: .sent,
            dataFlow: .init(
                location: .local, targetID: ThisMacProvider.id, targetName: "This Mac", startedAt: start,
                endedAt: start.addingTimeInterval(0.375), bodies: ["System Audio"], purpose: "Live transcription"))
        try DataEventJournal.append(event, directory: directory)
        let file = directory.appendingPathComponent(DataEventJournal.filename)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"interrupted\":".utf8))
        try handle.close()
        var later = event
        later.id = UUID()
        try DataEventJournal.append(later, directory: directory)
        let events = try DataEventJournal.read(directory: directory)
        #expect(events.map(\.id) == [event.id, later.id])
        let restored = try #require(events.first?.dataFlow)
        #expect(abs(restored.startedAt.timeIntervalSince(start)) < 0.001)
        #expect(abs(try #require(restored.duration) - 0.375) < 0.001)
        #expect(restored.requestBytes == nil)
        #expect(restored.responseBytes == nil)
        #expect(try Data(contentsOf: file).last == 10)
    }

    @Test func fileHistoryRecordsChangesWithoutContentOrRecursiveEvents() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notes.md")
        let original = Data("Synthetic first note".utf8)
        try original.write(to: file)
        try DataEventJournal.fileChanged(file, previous: nil)
        try DataEventJournal.fileChanged(file, previous: original)
        let updated = Data("Synthetic updated note".utf8)
        try updated.write(to: file)
        try DataEventJournal.fileChanged(file, previous: original)
        try DataEventJournal.fileChanged(directory.appendingPathComponent(DataEventJournal.filename), previous: nil)
        let events = try DataEventJournal.read(directory: directory)
        #expect(events.map(\.action) == [.created, .modified])
        #expect(events.allSatisfy { $0.dataFlow.bodies == ["notes.md"] })
        #expect(events.last?.dataFlow.responseBytes == updated.count)
        let text = try String(contentsOf: directory.appendingPathComponent(DataEventJournal.filename), encoding: .utf8)
        #expect(!text.contains("Synthetic first note"))
        #expect(!text.contains("Synthetic updated note"))
    }

    @MainActor @Test func failedMeetingSaveDoesNotRecordProposedChanges() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let id = store.createMeeting(title: "Synthetic meeting")
        let folder = store.directory(for: id)
        let before = try DataEventJournal.read(directory: folder)
        var meeting = try #require(store.meeting(id: id))
        let metadata = folder.appendingPathComponent("metadata.json")
        try FileManager.default.moveItem(at: metadata, to: directory.appendingPathComponent("metadata-backup.json"))
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        meeting.summary = "Synthetic proposed summary"
        #expect(!store.updateMeeting(meeting))
        #expect(try DataEventJournal.read(directory: folder) == before)
    }

    @MainActor @Test func contextualChatNamesItsOwnHistoryWithoutClaimingMeetingChatWasSent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        var meeting = Meeting(title: "Synthetic meeting")
        meeting.notes = "Synthetic note"
        meeting.summary = "Synthetic summary"
        meeting.chat = [.init(role: "user", content: "Synthetic private meeting question")]
        let contextual = store.chatDataBodies(meeting, contextual: true)
        #expect(contextual.contains("context-chats.json (library folder)"))
        #expect(!contextual.contains("content.json (chat)"))
        #expect(contextual.contains("notes.md"))
        #expect(contextual.contains("summary.md"))
        let direct = store.chatDataBodies(meeting)
        #expect(direct.contains("content.json (chat)"))
        #expect(!direct.contains("context-chats.json (library folder)"))
    }

    @MainActor @Test func summaryReceiptReferencesLanguageInContentFile() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let bodies = store.summaryDataBodies(Meeting(title: "Synthetic meeting", language: "en"), messages: [])
        #expect(bodies.contains("content.json (language)"))
        #expect(bodies.contains("metadata.json (title, date, duration)"))
        #expect(!bodies.contains("metadata.json (title, date, duration, language)"))
    }

    @Test func archiveReceiptNamesSnapshotArtifactsAndAudioWithoutPayloadsOrURLs() {
        let bodies = GdayServerService.archiveDataBodies([
            "artifacts": ["notes.md": "Synthetic private note", "assets/diagram.png": ["data": "synthetic-base64"]],
            "audio": [["filename": "microphone.opus", "url": "https://example.invalid/audio?token=synthetic"]],
        ])
        #expect(
            bodies == [
                "server-archive.json (meeting metadata, people and tags)",
                "assets/diagram.png (archived snapshot in server-archive.json)",
                "notes.md (archived snapshot in server-archive.json)",
                "microphone.opus (audio download link)",
            ])
        #expect(!bodies.joined().contains("Synthetic private note"))
        #expect(!bodies.joined().contains("token"))
        #expect(!bodies.joined().contains("synthetic-base64"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("data-event-tests-" + UUID().uuidString)
    }
}
