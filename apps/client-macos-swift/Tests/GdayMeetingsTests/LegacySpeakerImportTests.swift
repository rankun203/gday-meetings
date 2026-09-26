import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct LegacySpeakerImportTests {
    @Test func preservesTrackLabelsAssignmentsAndConfirmedSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-speakers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rust")
        let session = source.appendingPathComponent("recordings/session-one")
        try write(["name": "Imported speakers"], to: session.appendingPathComponent("metadata.json"))
        try write(["name": "Alex", "notes": "Design"], to: source.appendingPathComponent("people/p_alex/profile.json"))
        try write(["name": "Blair"], to: source.appendingPathComponent("people/p_blair/profile.json"))
        try write(
            [
                "centroid": [1.0, 0.0],
                "samples": [
                    ["embedding": [1.0, 0.0], "session_id": "session-one"],
                    ["embedding": [0.5, 0.5], "session_id": "older-session"],
                    ["embedding": [0.0, 0.0], "session_id": "session-one"],
                ],
            ], to: source.appendingPathComponent("people/p_alex/embeddings.json"))
        let transcript: [String: Any] = [
            "segments": [
                ["speaker": "SPEAKER_00", "track": "microphone", "start": 0, "end": 1, "text": "Hello"],
                ["speaker": "SPEAKER_00", "track": "system", "start": 1, "end": 2, "text": "Reply"],
                ["speaker": "SPEAKER_00", "track": "microphone", "start": 2, "end": 3, "text": "Again"],
                ["speaker": "SPEAKER_01", "track": "system", "start": 3, "end": 4, "text": "Suggestion"],
                ["speaker": "SPEAKER_02", "track": "system", "start": 4, "end": 5, "text": "Unknown"],
            ],
            "speaker_embeddings": [
                "SPEAKER_00": ["person_id": "p_alex", "embedding": [1.0, 0.0], "confidence": 0.88],
                "SPEAKER_01": ["person_id": "p_blair", "embedding": [0.2, 0.8], "confidence": 1.0],
                "SPEAKER_02": ["person_id": "missing-person", "embedding": [0.0, 0.0], "confidence": 0.91],
            ],
        ]
        try write(transcript, to: session.appendingPathComponent("transcript.json"))
        try write(
            [
                "tracks": [
                    "microphone": ["speaker_embeddings": ["SPEAKER_00": [1.0, 0.0]]],
                    "system": ["speaker_embeddings": ["SPEAKER_00": [0.0, 1.0]]],
                ]
            ], to: session.appendingPathComponent("extraction_raw.json"))
        let original = try Data(contentsOf: session.appendingPathComponent("transcript.json"))
        let destination = root.appendingPathComponent("swift")
        let store = MeetingStore(dataDirectory: destination)
        // A single recording folder must still resolve the Rust people library.
        #expect(try store.importLegacyLibrary(url: session) == 1)
        let meeting = try #require(store.meetings.first)
        let alex = try #require(store.people.first { $0.name == "Alex" })
        let blair = try #require(store.people.first { $0.name == "Blair" })
        #expect(meeting.speakers.count == 4)
        #expect(meeting.transcript[0].speaker == "SPEAKER_00")
        #expect(meeting.transcript[0].speakerID == meeting.transcript[2].speakerID)
        #expect(meeting.transcript[0].speakerID != meeting.transcript[1].speakerID)
        let microphone = try #require(meeting.speakers.first { $0.track == "microphone" })
        let system = try #require(meeting.speakers.first { $0.track == "system" && $0.label == "SPEAKER_00" })
        #expect(microphone.personID == alex.id && microphone.confirmed)
        #expect(microphone.confidence == 0.88)
        #expect(microphone.embedding == [1, 0])
        #expect(system.personID == alex.id && !system.confirmed)
        #expect(system.embedding == [0, 1])
        let suggested = try #require(meeting.speakers.first { $0.label == "SPEAKER_01" })
        #expect(suggested.personID == blair.id && !suggested.confirmed)
        #expect(suggested.confidence == 1)
        let unknown = try #require(meeting.speakers.first { $0.label == "SPEAKER_02" })
        #expect(unknown.personID == nil && !unknown.confirmed && unknown.embedding == nil)
        #expect(meeting.personIDs == [alex.id])
        #expect(alex.voiceSamples.count == 2)
        #expect(alex.voiceSamples.allSatisfy { $0.scope == "legacy:rust" })
        #expect(alex.voiceSamples.first?.meetingID == meeting.id)
        #expect(alex.voiceSamples.first?.speakerID == microphone.id)
        #expect(meeting.speakerName(for: meeting.transcript[0], people: store.people) == "Alex")
        #expect(try Data(contentsOf: session.appendingPathComponent("transcript.json")) == original)

        var current = [
            MeetingSpeaker(
                label: "SPEAKER_00", track: "microphone", providerName: "RunPod",
                voiceScope: "runpod:https://example.invalid", embedding: [1, 0])
        ]
        SpeakerRecognition.suggest(&current, people: store.people)
        #expect(current[0].personID == nil)
        let reopened = MeetingStore(dataDirectory: destination)
        #expect(reopened.meetings.first?.speakers == meeting.speakers)
        #expect(reopened.people.first { $0.id == alex.id }?.voiceSamples == alex.voiceSamples)
    }

    @Test func malformedOptionalVoiceDataDoesNotBlockTextImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-optional-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rust")
        let session = source.appendingPathComponent("recordings/session")
        try write(["name": "Usable text"], to: session.appendingPathComponent("metadata.json"))
        try write(
            [
                "segments": [["speaker": "SPEAKER_00", "track": "system", "text": "Keep this"]],
                "speaker_embeddings": ["SPEAKER_00": ["embedding": [1.0, 0.0]]],
            ], to: session.appendingPathComponent("transcript.json"))
        try Data("{bad json".utf8).write(to: session.appendingPathComponent("extraction_raw.json"))
        let person = source.appendingPathComponent("people/p_one")
        try write(["name": "Alex"], to: person.appendingPathComponent("profile.json"))
        try write(
            [
                "samples": [
                    ["embedding": [1.0, 0.0], "session_id": "session"],
                    ["embedding": "invalid", "session_id": "session"],
                    ["embedding": [1.0, 0.0]],
                ]
            ], to: person.appendingPathComponent("embeddings.json"))
        let second = source.appendingPathComponent("people/p_two")
        try write(["name": "Blair"], to: second.appendingPathComponent("profile.json"))
        try Data("{bad json".utf8).write(to: second.appendingPathComponent("embeddings.json"))
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("swift"))
        #expect(try store.importLegacyLibrary(url: source) == 1)
        #expect(store.meetings.first?.transcript.first?.text == "Keep this")
        #expect(store.meetings.first?.speakers.first?.embedding == [1, 0])
        #expect(store.people.first { $0.name == "Alex" }?.voiceSamples.count == 1)
        #expect(store.people.first { $0.name == "Blair" }?.voiceSamples.isEmpty == true)
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
}
