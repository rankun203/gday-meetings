import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct RecordingDefaultsTests {
    @Test func defaultLanguageModeResolvesAndPersists() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"defaultLanguage":"de"}"#.utf8))
        #expect(settings.useLastRecordingLanguage)
        #expect(settings.effectiveDefaultLanguage == "de")
        settings.lastRecordingLanguage = "fr"
        #expect(settings.effectiveDefaultLanguage == "fr")
        settings.defaultLanguageSelection = "ja"
        #expect(settings.effectiveDefaultLanguage == "ja")
        settings.lastRecordingLanguage = "es"
        #expect(settings.effectiveDefaultLanguage == "ja")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.defaultLanguageSelection == "ja")
        #expect(restored.lastRecordingLanguage == "es")
        settings.defaultLanguageSelection = AppSettings.lastRecordingLanguageSelection
        #expect(settings.effectiveDefaultLanguage == "es")
    }

    @Test func failedStartPreservesSavedDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        store.settings.captureMicrophone = true
        store.settings.captureSystemAudio = true
        store.settings.recordingFormat = .opus
        store.saveSettings()
        let defaults = store.settings

        // No sources fails before opening devices or requesting permission.
        await store.startRecording(language: "fr", microphoneEnabled: false, systemEnabled: false, format: .wav)

        #expect(store.recordingID == nil)
        #expect(store.errorMessage != nil)
        #expect(!store.recordingLevels.microphone.enabled)
        #expect(!store.recordingLevels.system.enabled)
        #expect(store.settings == defaults)
        #expect(MeetingStore(dataDirectory: directory).settings == defaults)
    }

    @Test func recordingLanguagePersistsAcrossLaunches() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)

        store.rememberRecordingLanguage("fr")

        #expect(store.settings.effectiveDefaultLanguage == "fr")
        #expect(MeetingStore(dataDirectory: directory).settings.effectiveDefaultLanguage == "fr")
    }

    @Test func meetingCreationAndProviderHealthUseResolvedLanguage() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        store.settings.defaultLanguage = "ja"
        store.settings.lastRecordingLanguage = "fr"

        let remembered = await store.createMeeting()
        #expect(store.meeting(id: remembered)?.language == "fr")
        #expect(ProviderHealthStore.Configuration(store.settings).language == "fr")

        store.settings.defaultLanguageSelection = "ja"
        let fixed = await store.createMeeting()
        #expect(store.meeting(id: fixed)?.language == "ja")
        #expect(ProviderHealthStore.Configuration(store.settings).language == "ja")
    }

    @Test func activeRecordingLanguageChangesAreRemembered() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let id = await store.createMeeting(language: "en")
        store.recordingID = id
        var meeting = store.meeting(id: id)!
        meeting.language = "fr"

        #expect(await store.updateMeeting(meeting))
        #expect(MeetingStore(dataDirectory: directory).settings.effectiveDefaultLanguage == "fr")

        store.recordingID = nil
        meeting.language = "de"
        #expect(await store.updateMeeting(meeting))
        #expect(MeetingStore(dataDirectory: directory).settings.effectiveDefaultLanguage == "fr")
    }

    @Test func languageEditFinishingAfterStopIsRemembered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        let id = await store.createMeeting(language: "en")
        store.recordingID = id
        var meeting = try #require(store.meeting(id: id))
        meeting.language = "fr"
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        defer { releaseContinuation.finish() }
        let earlier = Task {
            await store.enqueueCanonical {
                enteredContinuation.yield(())
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
                return true
            }
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        let edit = Task { await store.updateMeeting(meeting) }
        for _ in 0..<100 where store.meeting(id: id)?.language != "fr" {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(store.meeting(id: id)?.language == "fr")
        store.recordingID = nil
        releaseContinuation.yield(())
        #expect(await earlier.value)
        #expect(await edit.value)
        #expect(MeetingStore(dataDirectory: directory).settings.effectiveDefaultLanguage == "fr")
    }
}
