import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct RecordingFinalizationTests {
    @Test func alreadyOpusTracksAreNeverReencodedOrRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic capture")
        let folder = store.directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("microphone.opus")
        let original = OpusFixture.all[0].data
        try original.write(to: source)
        var meeting = try #require(store.meetings.first)
        meeting.audioFiles = [source.lastPathComponent]
        await store.updateMeeting(meeting)
        try await store.finalizeRecordingAudio(id: id, format: .opus)
        #expect(try Data(contentsOf: source) == original)
        #expect(store.meeting(id: id)?.audioFiles == ["microphone.opus"])
    }

    @Test func savedCompressedTracksReplacePCMOnlyAfterMetadataCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic capture")
        let folder = store.directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("microphone.wav")
        try writeFixture(source)
        var meeting = try #require(store.meetings.first)
        meeting.audioFiles = [source.lastPathComponent]
        await store.updateMeeting(meeting)
        try await store.finalizeRecordingAudio(id: id, format: .m4a)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let reloaded = MeetingStore(dataDirectory: root)
        #expect(await reloaded.ensureMeetingLoaded(id: id))
        #expect(reloaded.meeting(id: id)?.audioFiles == ["microphone.m4a"])
        let result = try AVAudioFile(forReading: folder.appendingPathComponent("microphone.m4a"))
        #expect(abs(Double(result.length) / result.fileFormat.sampleRate - 0.1) < 0.05)
    }

    @Test func failedMetadataCommitRetainsPCMAndRemovesConvertedCopy() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic capture")
        let folder = store.directory(for: id)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("microphone.wav")
        try writeFixture(source)
        let original = try Data(contentsOf: source)
        var meeting = try #require(store.meetings.first)
        meeting.audioFiles = [source.lastPathComponent]
        await store.updateMeeting(meeting)
        let library = store.directory(for: id).appendingPathComponent("metadata.json")
        try files.moveItem(at: library, to: root.appendingPathComponent("saved-library.json"))
        try files.createDirectory(at: library, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await store.finalizeRecordingAudio(id: id, format: .m4a) }
        #expect(try Data(contentsOf: source) == original)
        #expect(store.meetings.first?.audioFiles == ["microphone.wav"])
        #expect(!files.fileExists(atPath: folder.appendingPathComponent("microphone.m4a").path))
    }

    @Test func olderSettingsChooseOpusAndPersistFormatSelection() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.recordingFormat == .opus)
        var selected = old
        selected.recordingFormat = .m4a
        #expect(
            try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(selected)).recordingFormat == .m4a)
    }

    private func writeFixture(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for frame in 0..<4800 { buffer.floatChannelData![0][frame] = 0.2 * sin(Float(frame) * 0.1) }
        let writer = try TimedAudioWriter(url: url, format: format, epoch: 0)
        try writer.append(buffer, hostSeconds: 0)
        try writer.finish()
    }
}
