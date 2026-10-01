import Foundation
import Testing

@testable import GdayMeetings

struct DataFlowIdentityTests {
    @Test func identityAndExplicitPathsSurviveEncoding() throws {
        let id = UUID()
        let flow = DataFlow(
            location: .remote, targetID: id, targetName: "Original Provider", startedAt: Date(),
            bodies: ["source (draft).opus (converted for upload)"], filePaths: ["source (draft).opus"],
            purpose: "Audio upload")
        let restored = try JSONDecoder().decode(DataFlow.self, from: JSONEncoder().encode(flow))
        #expect(restored == flow)
        #expect(restored.targetID == id)
        #expect(restored.filePaths == ["source (draft).opus"])
    }

    @Test func resolutionUsesIdentityAcrossRenamesAndDuplicateNames() {
        var selected = ServiceProvider(kind: .runpod)
        selected.name = "Shared Name"
        var other = ServiceProvider(kind: .runpod)
        other.name = selected.name
        let flow = receipt(targetID: selected.id, targetName: selected.name)
        selected.name = "Renamed Provider"
        #expect(flow.resolvedTargetName(providers: [selected.id: selected, other.id: other]) == "Renamed Provider")
        #expect(flow.targetName == "Shared Name")
        // Deleting the selected provider cannot redirect its receipt to a namesake.
        #expect(flow.resolvedTargetName(providers: [other.id: other]) == "Shared Name")
        #expect(flow.resolvedTargetName(providers: [:]) == "Shared Name")
    }

    @Test func thisMacResolvesByItsReservedID() {
        let flow = receipt(targetID: ThisMacProvider.id, targetName: "Saved Local Name")
        #expect(flow.resolvedTargetName(providers: [:]) == "This Mac")
        // A provider named This Mac still has its own identity.
        var provider = ServiceProvider(kind: .openAICompatible)
        let remote = receipt(targetID: provider.id, targetName: "This Mac")
        provider.name = "Renamed Service"
        #expect(remote.resolvedTargetName(providers: [provider.id: provider]) == "Renamed Service")
    }

    @Test func legacyReceiptsNeverInferIdentityOrPaths() throws {
        for name in ["This Mac", "Existing Provider"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "location": "local", "targetName": name, "startedAt": 0,
                "bodies": ["audio (draft).opus (converted for upload)"], "purpose": "Audio upload",
            ])
            let flow = try JSONDecoder().decode(DataFlow.self, from: data)
            var provider = ServiceProvider(kind: .runpod)
            provider.name = name
            #expect(flow.targetID == nil)
            #expect(flow.filePaths.isEmpty)
            #expect(flow.resolvedTargetName(providers: [provider.id: provider]) == name)
            provider.name = "Renamed Provider"
            #expect(flow.resolvedTargetName(providers: [provider.id: provider]) == name)
            let restored = try JSONDecoder().decode(DataFlow.self, from: JSONEncoder().encode(flow))
            #expect(restored.targetID == nil)
            #expect(restored.filePaths.isEmpty)
        }
    }

    @Test func malformedIdentityIsNotTreatedAsLegacy() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "location": "remote", "targetID": "invalid-uuid", "targetName": "Example Provider",
            "startedAt": 0, "bodies": [], "purpose": "Summary",
        ])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DataFlow.self, from: data) }
    }

    @Test func localEndpointKeepsProviderIdentityAndExplicitPaths() async throws {
        let id = UUID()
        let result = try await ProviderDataOperation.perform(
            targetID: id, target: "Local Service", endpoint: "http://localhost:8080",
            bodies: ["notes.md (summary input)"], filePaths: ["notes.md"], purpose: "Summary"
        ) { true }
        #expect(result.dataFlow.location == .local)
        #expect(result.dataFlow.targetID == id)
        #expect(result.dataFlow.targetID != ThisMacProvider.id)
        #expect(result.dataFlow.filePaths == ["notes.md"])
    }

    @Test func audioReferencesKeepLiteralFilenamesAndIdentity() {
        let id = UUID()
        let flow = receipt(targetID: id, targetName: "Example Provider")
        let file = URL(fileURLWithPath: "/synthetic/meeting/audio (draft).wav")
        let prepared = URL(fileURLWithPath: "/synthetic/conversion/upload.m4a")
        let converted = flow.referencing(file: file, prepared: prepared)
        #expect(converted.targetID == id)
        #expect(converted.filePaths == ["audio (draft).wav"])
        #expect(converted.bodies == ["audio (draft).wav (converted to M4A for upload)"])
        let tracks = flow.referencingAudio([
            file, file.deletingLastPathComponent().appendingPathComponent("system.opus"),
        ])
        #expect(tracks.targetID == id)
        #expect(tracks.filePaths == ["audio (draft).wav", "system.opus"])
    }

    @Test func localFileReceiptsCarryMeetingRelativePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("image (draft).png")
        try Data([0, 1, 2]).write(to: file)
        try DataEventJournal.fileChanged(file, previous: nil, directory: root)
        try DataEventJournal.fileSaved(file, action: .modified, directory: root)
        let events = try DataEventJournal.read(directory: root)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.dataFlow.targetID == ThisMacProvider.id })
        #expect(events.allSatisfy { $0.dataFlow.filePaths == ["assets/image (draft).png"] })
        #expect(events.allSatisfy { $0.dataFlow.bodies == ["assets/image (draft).png"] })
    }

    @MainActor @Test func summaryAndChatPathsExcludeLibraryScopedDescriptors() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        var meeting = Meeting(title: "Synthetic meeting")
        meeting.notes = "Synthetic note"
        meeting.summary = "Synthetic summary"
        #expect(store.summaryDataFilePaths(meeting, messages: []) == ["metadata.json", "content.json", "notes.md"])
        #expect(store.chatDataFilePaths(meeting) == ["metadata.json", "content.json", "notes.md", "summary.md"])
        #expect(store.chatDataFilePaths(meeting, contextual: true) == ["metadata.json", "notes.md", "summary.md"])
    }

    private func receipt(targetID: UUID, targetName: String) -> DataFlow {
        DataFlow(
            location: .remote, targetID: targetID, targetName: targetName, startedAt: Date(),
            bodies: [], purpose: "Synthetic operation")
    }
}
