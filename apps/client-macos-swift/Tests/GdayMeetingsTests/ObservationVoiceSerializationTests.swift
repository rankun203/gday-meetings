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
    @Test func humanReviewWaitsForCaptureCommitAndSurvivesNextSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let meetingID = await store.createMeeting(title: "Capture and review")
        let personID = await store.addPerson(name: "Reviewed person")
        var meeting = try #require(store.meeting(id: meetingID))
        meeting.audioFiles = ["microphone.wav"]
        #expect(await store.updateMeeting(meeting))
        #expect(await store.voiceLibrary.awaitReady())
        store.recordingID = meetingID
        let type = EmbeddingType(
            modelID: "fixture", revision: "1", compatibilityVersion: "1",
            dimension: 2, normalization: "unitL2")
        let speaker = UUID()
        let first = SpeakerEvidenceSample(
            id: "review-before-next-snapshot", source: "microphone", localSpeakerID: "one", start: 0, end: 3,
            embedding: .init(type: type, values: [1, 0]))
        let next = SpeakerEvidenceSample(
            id: "better-representative", source: "microphone", localSpeakerID: "one", start: 5, end: 8,
            embedding: .init(type: type, values: [1, 0]))
        #expect(
            await store.recordObservationVoiceExamples(
                meetingID: meetingID, representatives: [.init(sample: first, meetingSpeakerID: speaker)]))
        let firstID = try #require(store.voiceLibrary.examples.first { $0.observationID == first.id }?.id)
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        store.voiceLibrary.beforeObservationCommit = {
            entered.continuation.yield(())
            release.wait()
        }
        let capture = Task {
            await store.recordObservationVoiceExamples(
                meetingID: meetingID,
                representatives: [
                    .init(sample: first, meetingSpeakerID: speaker), .init(sample: next, meetingSpeakerID: speaker),
                ])
        }
        for await _ in entered.stream { break }
        var reviewCompleted = false
        let review = Task {
            let result = await store.reviewVoiceExamples(.confirm(ids: [firstID], personID: personID))
            reviewCompleted = true
            return result
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!reviewCompleted)
        store.voiceLibrary.beforeObservationCommit = nil
        release.signal()
        #expect(await capture.value)
        #expect(await review.value)
        #expect(
            await store.recordObservationVoiceExamples(
                meetingID: meetingID, representatives: [.init(sample: next, meetingSpeakerID: speaker)]))
        let reviewed = try #require(store.voiceLibrary.examples.first { $0.id == firstID })
        #expect(reviewed.review == .confirmed)
        #expect(reviewed.personID == personID)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(reopened.examples.first { $0.id == firstID }?.personID == personID)
        #expect(await store.flushCanonicalWrites())
    }

    @Test func staleSelectionDoesNotPartiallyApplyToRemainingExamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let meetingID = await store.createMeeting(title: "Stale voice selection")
        let personID = await store.addPerson(name: "Reviewed person")
        var meeting = try #require(store.meeting(id: meetingID))
        meeting.audioFiles = ["microphone.wav"]
        #expect(await store.updateMeeting(meeting))
        #expect(await store.voiceLibrary.awaitReady())
        store.recordingID = meetingID
        let type = EmbeddingType(
            modelID: "fixture", revision: "1", compatibilityVersion: "1",
            dimension: 2, normalization: "unitL2")
        let speaker = UUID()
        let first = SpeakerEvidenceSample(
            id: "retired-selection", source: "microphone", localSpeakerID: "one", start: 0, end: 3,
            embedding: .init(type: type, values: [1, 0]))
        let retained = SpeakerEvidenceSample(
            id: "retained-selection", source: "microphone", localSpeakerID: "one", start: 5, end: 8,
            embedding: .init(type: type, values: [1, 0]))
        #expect(
            await store.recordObservationVoiceExamples(
                meetingID: meetingID,
                representatives: [
                    .init(sample: first, meetingSpeakerID: speaker), .init(sample: retained, meetingSpeakerID: speaker),
                ]))
        let selected = Set(store.voiceLibrary.examples.map(\.id))
        // Construct the action before capture retires one of the selected examples.
        let action = VoiceReviewAction.confirm(ids: selected, personID: personID)
        #expect(
            await store.recordObservationVoiceExamples(
                meetingID: meetingID, representatives: [.init(sample: retained, meetingSpeakerID: speaker)]))
        #expect(!(await store.reviewVoiceExamples(action)))
        #expect(store.voiceLibrary.examples.count == 1)
        #expect(store.voiceLibrary.examples.first?.personID == nil)
        #expect(store.voiceLibrary.examples.first?.review == .unassigned)
        #expect(store.errorMessage == "This voice example changed while saving. Select an example again.")
        #expect(await store.flushCanonicalWrites())
    }

}
