import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct VoiceFragmentReviewTests {
    @Test func supportRoundTripAndConflictDetectionExcludeInterveningVoice() throws {
        let spans: [SpeakerEvidenceSpan] = [.init(start: 0, end: 1), .init(start: 3, end: 4)]
        let person = UUID()
        let otherPerson = UUID()
        let meeting = UUID()
        let first = VoiceExample(
            meetingID: meeting, speakerID: UUID(), source: "system", audioFile: "system.wav",
            start: 0, end: 4, personID: person, review: .confirmed, spans: spans)
        var other = VoiceExample(
            meetingID: meeting, speakerID: UUID(), source: "system", audioFile: "system.wav",
            start: 1, end: 3, personID: otherPerson, review: .confirmed)
        let decoded = try JSONDecoder().decode(VoiceExample.self, from: JSONEncoder().encode(first))
        #expect(decoded == first)
        #expect(decoded.range?.speechDuration == 2)
        let encodedRange = try JSONEncoder().encode(#require(decoded.range))
        let roundTripRange = try JSONDecoder().decode(VoiceSampleRange.self, from: encodedRange)
        #expect(roundTripRange == decoded.range)
        let legacy = try JSONSerialization.jsonObject(with: encodedRange) as? [String: Any]
        #expect(legacy?["start"] as? Double == 0)
        #expect(legacy?["end"] as? Double == 0)
        #expect(decoded.range?.contains(start: 1.5, end: 2) == false)
        #expect(VoiceReviewConflicts.confirmedExampleIDs(in: [first, other]).isEmpty)
        other.start = 0.5
        #expect(VoiceReviewConflicts.confirmedExampleIDs(in: [first, other]) == [first.id, other.id])
        var invalid = first
        invalid.spans = [.init(start: 0, end: 2), .init(start: 1, end: 4)]
        #expect(invalid.range == nil)
    }

    @Test func savedFragmentExtractionReadsOnlySupportedPCM() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("system.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000))
        buffer.frameLength = 192000
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<192000 { channel[index] = index < 48000 ? 0.2 : index < 144000 ? 0.8 : -0.4 }
        try Self.writeBuffer(buffer, to: url)
        let samples = try LocalVoiceExampleExtractor.readSamples(
            url: url,
            spans: [
                .init(start: 0, end: 1), .init(start: 3, end: 4),
            ])
        #expect(abs(samples.count - 32000) < 10)
        #expect(samples[8000] > 0.19 && samples[8000] < 0.21)
        #expect(samples[24000] < -0.39 && samples[24000] > -0.41)
        let nonzero = try LocalVoiceExampleExtractor.readSamples(
            url: url,
            spans: [
                .init(start: 0.13, end: 1.13), .init(start: 2.37, end: 3.37),
            ])
        #expect(nonzero.count == 32000)
        #expect(throws: (any Error).self) {
            try LocalVoiceExampleExtractor.readSamples(url: url, spans: [.init(start: 0, end: 1)])
        }
    }

    @Test func sharedPlayerAdvancesBetweenBoundedFragmentsAndClearsOnSeek() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("system.wav")
        try Self.writeSilence(url)
        let meeting = Meeting(title: "Fragment review", audioFiles: ["system.wav"])
        let playback = MeetingPlayback()
        defer { playback.clear() }
        let spans: [SpeakerEvidenceSpan] = [.init(start: 0, end: 0.1), .init(start: 1, end: 1.1)]
        playback.playExcerpts(meeting: meeting, directory: directory, audioFile: "system.wav", spans: spans)
        playback.pause()
        await playback.waitForPreparation()
        #expect(playback.excerptRanges == [0..<0.1, 1..<1.1])
        #expect(playback.excerptRange == 0..<0.1)
        playback.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !playback.hasEnded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(playback.errorMessage == nil)
        #expect(playback.hasEnded)
        #expect(playback.excerptRange == 1..<1.1)
        #expect(playback.currentTime >= 1 && playback.currentTime <= 1.11)
        playback.seek(to: 0.5)
        #expect(playback.excerptRange == nil)
        #expect(playback.excerptRanges.isEmpty)
    }

    private static func writeBuffer(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        try AVAudioFile(forWriting: url, settings: buffer.format.settings).write(from: buffer)
    }

    private static func writeSilence(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = 96000
        let channel = try #require(buffer.floatChannelData?[0])
        channel.initialize(repeating: 0, count: 96000)
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    @Test func fragmentedLibraryUsesVersionTwoAndPreservesSupportAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: "system.wav",
            start: 0, end: 4, spans: [.init(start: 0, end: 1), .init(start: 3, end: 4)])
        #expect(library.upsert([sample]))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.examples.first?.spans == sample.spans)
        let header =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf:
                        directory.appendingPathComponent("voice-library/state.json"))) as? [String: Any]
        #expect(header?["version"] as? Int == 2)
    }
}
