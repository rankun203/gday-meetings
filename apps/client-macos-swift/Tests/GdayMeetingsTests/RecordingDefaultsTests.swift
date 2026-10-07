import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct RecordingDefaultsTests {
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
