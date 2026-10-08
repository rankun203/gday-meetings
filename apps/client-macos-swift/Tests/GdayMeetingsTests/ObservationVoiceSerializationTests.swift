import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct ObservationVoiceSerializationTests {
    @Test func finalRepresentativeSnapshotWaitsForHumanVoiceCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let meetingID = await store.createMeeting(title: "Serialized voice evidence")
        let personID = await store.addPerson(name: "Reviewed person")
        var meeting = try #require(store.meeting(id: meetingID))
        meeting.audioFiles = ["microphone.wav"]
        #expect(await store.updateMeeting(meeting))
        #expect(await store.voiceLibrary.awaitReady())
        store.recordingID = meetingID
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        store.canonicalWriteHook = {
            entered.continuation.yield(())
            release.wait()
        }
        let reviewedSpeaker = UUID()
        let enrollment = Task {
            await store.enrollLiveVoice(
                meetingID: meetingID, personID: personID,
                speakerID: reviewedSpeaker, embedding: nil)
        }
        for await _ in entered.stream { break }
        let type = EmbeddingType(
            modelID: "fixture", revision: "1", compatibilityVersion: "1",
            dimension: 2, normalization: "unitL2")
        let sample = SpeakerEvidenceSample(
            id: "last-recording-observation", source: "microphone",
            localSpeakerID: UUID().uuidString, start: 5, end: 8,
            embedding: .init(type: type, values: [1, 0]))
        let snapshot = Task {
            await store.recordObservationVoiceExamples(
                meetingID: meetingID,
                representatives: [.init(sample: sample, meetingSpeakerID: UUID())])
        }
        // Keep the actual canonical voice reservation open while the callback
        // arrives, reproducing the final-snapshot loss rather than mocking a flag.
        try await Task.sleep(for: .milliseconds(50))
        store.canonicalWriteHook = nil
        release.signal()
        await enrollment.value
        #expect(await snapshot.value)
        #expect(store.voiceLibrary.examples.contains { $0.observationID == sample.id })
        #expect(
            store.voiceLibrary.decisions.contains {
                $0.speakerID == reviewedSpeaker && $0.personID == personID
            })
        let reopened = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(reopened.examples.contains { $0.observationID == sample.id })
        #expect(reopened.decisions.contains { $0.speakerID == reviewedSpeaker && $0.personID == personID })
        #expect(await store.flushCanonicalWrites())
    }
}
