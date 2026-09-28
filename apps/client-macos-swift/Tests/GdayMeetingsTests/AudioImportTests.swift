import AVFoundation
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import GdayMeetings

@MainActor struct AudioImportTests {
    @Test func previewProviderOffersFileURL() async throws {
        let provider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/sample.wav") as NSURL)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let received: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url {
                    continuation.resume(returning: url)
                }
                else {
                    continuation.resume(throwing: error ?? MeetingError.message("No dropped URL"))
                }
            }
        }
        #expect(received == URL(fileURLWithPath: "/tmp/sample.wav"))
    }

    private func fixture(_ folder: URL, name: String, seconds: Int) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 8000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.1 }
        try file.write(from: buffer)
        return url
    }

    @Test func multipleMeetingsAndDuplicateTrackNamesPersistWithoutChangingSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture(root.appendingPathComponent("a"), name: "voice.wav", seconds: 1)
        let second = try fixture(root.appendingPathComponent("b"), name: "voice.wav", seconds: 2)
        let original = try Data(contentsOf: first)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("library"))
        let ids = try await store.importAudioFiles([first, second])
        #expect(ids.count == 2)
        #expect(store.meetings.count == 2)
        #expect(store.meetings.allSatisfy { $0.audioFiles.count == 1 })
        var meeting = try #require(store.meetings.first)
        meeting.notes = "Keep notes"
        store.updateMeeting(meeting)
        _ = try await store.importAudioFiles([first, second], into: meeting.id)
        let restored = MeetingStore(dataDirectory: store.dataDirectory)
        let added = try #require(restored.meeting(id: meeting.id))
        #expect(added.audioFiles == ["voice.wav", "voice-2.wav", "voice-3.wav"])
        #expect(added.duration == 2)
        #expect(added.notes == "Keep notes")
        #expect(try Data(contentsOf: first) == original)
        #expect(try Data(contentsOf: restored.audioURLs(for: added)[0]) == original)
    }

    @Test func invalidBatchAndFailedSaveLeaveExistingTracksUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, name: "voice.wav", seconds: 1)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("library"))
        let id = try #require(try await store.importAudioFiles([source]).first)
        let old = try #require(store.meetings.first)
        let existingFiles = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: id).path).sorted()
        let bytes = try Data(contentsOf: store.audioURLs(for: old)[0])
        let invalid = root.appendingPathComponent("broken.wav")
        try Data("not audio".utf8).write(to: invalid)
        await #expect(throws: (any Error).self) { try await store.importAudioFiles([source, invalid], into: id) }
        #expect(store.meetings.first == old)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: store.directory(for: id).path).sorted() == existingFiles
        )
        let library = store.directory(for: id).appendingPathComponent("metadata.json")
        try FileManager.default.moveItem(at: library, to: root.appendingPathComponent("backup.json"))
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await store.importAudioFiles([source], into: id) }
        #expect(store.meetings.first == old)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: store.directory(for: id).path).sorted() == existingFiles
        )
        #expect(try Data(contentsOf: store.audioURLs(for: old)[0]) == bytes)
    }

    @Test func filenamesWithRepeatedDotsRemainPlayable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, name: "voice..part.wav", seconds: 1)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("library"))
        _ = try await store.importAudioFiles([source])
        let meeting = try #require(store.meetings.first)
        #expect(meeting.title == "voice..part")
        #expect(store.audioURLs(for: meeting).count == 1)
        #expect(meeting.audioFiles == ["voice_part.wav"])
    }

    @Test func activeCaptureAndPendingTranscriptionRejectTrackChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, name: "voice.wav", seconds: 1)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("library"))
        let id = store.createMeeting(title: "Existing")
        store.recordingID = id
        await #expect(throws: (any Error).self) { try await store.importAudioFiles([source], into: id) }
        store.recordingID = nil
        var meeting = try #require(store.meetings.first)
        meeting.transcriptionAttempt = ProviderTranscriptionAttempt(
            providerID: UUID(), endpoint: "https://example.com", kind: .gdayWebsite, title: "Existing",
            idempotencyKey: "saved")
        store.updateMeeting(meeting)
        await #expect(throws: (any Error).self) { try await store.importAudioFiles([source], into: id) }
        #expect(store.meetings.first == meeting)
    }

    @Test func importsContinueBesideOtherMeetingsJobsAndProtectActiveAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, name: "voice.wav", seconds: 1)
        let store = MeetingStore(dataDirectory: root.appendingPathComponent("library"))
        let id = store.createMeeting(title: "Processing audio")
        for kind: BackgroundJob.Kind in [.transcription, .archive] {
            #expect(store.beginJob(kind, .meeting(id), progress: "Processing audio…"))
            await #expect(throws: (any Error).self) { try await store.importAudioFiles([source], into: id) }
            let imported = try await store.importAudioFiles([source])
            #expect(imported.count == 1)
            #expect(store.isJobRunning(kind, .meeting(id)))
            #expect(!store.isImportingAudio)
            #expect(store.meetings.first { $0.id == id }?.audioFiles.isEmpty == true)
            store.endJob(kind, .meeting(id))
        }
    }
}
