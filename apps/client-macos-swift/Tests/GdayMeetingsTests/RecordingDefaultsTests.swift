import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct RecordingDefaultsTests {
    @Test func recordingStartCancelsExistingVoiceIndexPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        store.voiceSearch.rebuildSavedEmbeddings()
        #expect(store.voiceSearch.isBuilding)

        // No sources avoids opening capture devices while exercising the real
        // start boundary that must protect a newly growing recording.
        await store.startRecording(microphoneEnabled: false, systemEnabled: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.voiceSearch.isBuilding, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!store.voiceSearch.isBuilding)
        #expect(store.voiceSearch.statusMessage == "Index rebuilding stopped.")
        #expect(store.recordingID == nil)
    }

    @Test func sessionChoicesDoNotReplaceSavedDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        store.settings.captureMicrophone = true
        store.settings.captureSystemAudio = true
        store.settings.recordingFormat = .opus
        store.saveSettings()
        let defaults = store.settings

        // No sources fails before opening devices or requesting permission.
        await store.startRecording(microphoneEnabled: false, systemEnabled: false, format: .wav)

        #expect(store.recordingID == nil)
        #expect(store.errorMessage != nil)
        #expect(!store.recordingLevels.microphone.enabled)
        #expect(!store.recordingLevels.system.enabled)
        #expect(store.settings == defaults)
        #expect(MeetingStore(dataDirectory: directory).settings == defaults)
    }
}
