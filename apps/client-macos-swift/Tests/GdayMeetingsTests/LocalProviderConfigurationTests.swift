import Foundation
import Testing

@testable import GdayMeetings

struct LocalProviderConfigurationTests {
    @Test func localDiarizationNeedsNoNetworkCredentials() {
        let provider = ServiceProvider(kind: .speakerLabeling)
        #expect(provider.model == "community1")
        #expect(provider.supports(.diarization))
        #expect(provider.kind.capabilities == [.diarization])
        #expect(provider.localModelIDs(for: .diarization) == [.community1])
        #expect(provider.endpoint.isEmpty && provider.apiKey.isEmpty)
        #expect(ProviderConfigurationEligibility.canSelect(provider, for: .diarization, providers: []))
    }

    @MainActor @Test func savedLabelingRequiresSelectedEnabledCapability() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalProviderTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingStore(dataDirectory: folder)
        var meeting = Meeting(title: "Synthetic speaker check")
        meeting.transcript = [TranscriptSegment(start: 0, end: 1, speaker: "", text: "Example passage")]
        try await store.insertImportedMeeting(meeting)
        var disabled = ServiceProvider(kind: .speakerLabeling)
        disabled.isEnabled = false
        var labelsOff = ServiceProvider(kind: .speakerLabeling)
        labelsOff.enabledCapabilities = []
        for provider in [nil, disabled, labelsOff, ServiceProvider(kind: .openAICompatible)] {
            store.settings.serviceProviders = provider.map { [$0] } ?? []
            store.settings.diarizationProviderID = provider?.id
            await store.diarizeLocally(id: meeting.id)
            #expect(!store.isJobRunning(.diarization, .meeting(meeting.id)))
            #expect(!store.managedTasks.contains { $0.meetingID == meeting.id && $0.kind == .diarization })
            #expect(store.meeting(id: meeting.id)?.transcript == meeting.transcript)
        }
    }
}
