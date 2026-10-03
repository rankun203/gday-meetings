import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct TranscriptPlaybackVisibilityTests {
    private let meetingID = UUID()
    private let files = ["microphone.opus", "system.opus"]

    @MainActor @Test func pausedTransportMuteAndTrackMenuDriveVisibility() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["microphone.wav", "system.wav"].map { directory.appendingPathComponent($0) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        for url in urls {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
            buffer.frameLength = 16000
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 16000)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let meeting = Meeting(id: meetingID, audioFiles: urls.map(\.lastPathComponent))
        let rows = [
            TranscriptSegment(text: "Microphone passage", source: .microphone),
            TranscriptSegment(text: "System passage", source: .system),
        ]
        let playback = MeetingPlayback()
        defer { playback.clear() }
        playback.select(meeting: meeting, files: urls)
        await playback.waitForPreparation()
        #expect(playback.errorMessage == nil)
        func hidden() -> Set<UUID> {
            TranscriptPlaybackVisibility(
                meetingID: playback.meetingID,
                audioFiles: playback.trackNames.indices.compactMap {
                    playback.audioURL(forTrack: $0)?.lastPathComponent
                },
                mutedTracks: playback.mutedTracks
            ).hiddenSegments(meetingID: meetingID, segments: rows, speakers: [], audioFiles: meeting.audioFiles)
        }
        #expect(hidden().isEmpty)
        playback.toggleMute(0)
        #expect(hidden() == [rows[0].id])
        playback.toggleMute(1)
        #expect(hidden() == Set(rows.map(\.id)))
        playback.selectTrack(0)
        #expect(hidden() == [rows[1].id])
        playback.selectTrack(-1)
        #expect(hidden().isEmpty)
        #expect(!playback.isPlaying)
    }

    @Test func liveSourcesFollowEveryMixAndRestoreWithoutChangingContent() {
        let rows = [
            TranscriptSegment(start: 1, end: 5, text: "Microphone passage", source: .microphone),
            TranscriptSegment(start: 2, end: 6, text: "System passage", source: .system),
            TranscriptSegment(start: 3, end: 7, speaker: "mic_01", text: "Unknown source"),
        ]
        func hidden(_ muted: Set<Int>, playing: UUID?) -> Set<UUID> {
            TranscriptPlaybackVisibility(meetingID: playing, audioFiles: files, mutedTracks: muted)
                .hiddenSegments(meetingID: meetingID, segments: rows, speakers: [], audioFiles: files)
        }
        #expect(hidden([], playing: meetingID).isEmpty)
        #expect(hidden([0], playing: meetingID) == [rows[0].id])
        #expect(hidden([1], playing: meetingID) == [rows[1].id])
        #expect(hidden([0, 1], playing: meetingID) == [rows[0].id, rows[1].id])
        #expect(hidden([], playing: meetingID).isEmpty)
        #expect(hidden([0, 1], playing: UUID()).isEmpty)
        #expect(hidden([0, 1], playing: nil).isEmpty)
        #expect(rows.map(\.text) == ["Microphone passage", "System passage", "Unknown source"])
    }

    @Test func speakerTracksWorkForNamedSourcesAndProviderOrdinals() {
        let speakers = [
            MeetingSpeaker(label: "Person A", track: "mic", providerName: "Example"),
            MeetingSpeaker(label: "Person B", track: "system_mix", providerName: "Example"),
            MeetingSpeaker(label: "Person C", track: "track0", providerName: "Example"),
            MeetingSpeaker(label: "Person D", track: "track1", providerName: "Example"),
        ]
        let rows = speakers.map { TranscriptSegment(text: "Passage", speakerID: $0.id) }
        let filter = TranscriptPlaybackVisibility(meetingID: meetingID, audioFiles: files, mutedTracks: [1])
        #expect(
            filter.hiddenSegments(meetingID: meetingID, segments: rows, speakers: speakers, audioFiles: files)
                == [rows[1].id, rows[3].id])
    }

    @Test func missingFilesDoNotShiftProviderTrackIndices() {
        let speakers = [
            MeetingSpeaker(label: "A", track: "track0", providerName: "Example"),
            MeetingSpeaker(label: "B", track: "track1", providerName: "Example"),
            MeetingSpeaker(label: "C", track: "track9", providerName: "Example"),
        ]
        let rows = speakers.map { TranscriptSegment(text: "Passage", speakerID: $0.id) }
        let filter = TranscriptPlaybackVisibility(meetingID: meetingID, audioFiles: [files[1]], mutedTracks: [0])
        #expect(
            filter.hiddenSegments(meetingID: meetingID, segments: rows, speakers: speakers, audioFiles: files)
                == [rows[1].id])
    }

    @Test func ambiguousSourcesStayVisibleUntilEveryCandidateIsMuted() {
        let ambiguousFiles = ["microphone.wav", "microphone.opus", "system.wav"]
        let row = TranscriptSegment(text: "Microphone passage", source: .microphone)
        var filter = TranscriptPlaybackVisibility(meetingID: meetingID, audioFiles: ambiguousFiles, mutedTracks: [0])
        #expect(
            filter.hiddenSegments(meetingID: meetingID, segments: [row], speakers: [], audioFiles: ambiguousFiles)
                .isEmpty)
        filter.mutedTracks = [0, 1]
        #expect(
            filter.hiddenSegments(meetingID: meetingID, segments: [row], speakers: [], audioFiles: ambiguousFiles) == [
                row.id
            ])
    }

    @Test func importedAudioUsesExactProviderTrackAndDoesNotGuessFromSpeakerName() {
        let importedFiles = ["interview.wav", "translation.wav"]
        let speaker = MeetingSpeaker(label: "microphone", track: "track1", providerName: "Example")
        let rows = [
            TranscriptSegment(text: "Known source", speakerID: speaker.id),
            TranscriptSegment(speaker: "system", text: "Unattributed passage"),
        ]
        let filter = TranscriptPlaybackVisibility(meetingID: meetingID, audioFiles: importedFiles, mutedTracks: [0, 1])
        #expect(
            filter.hiddenSegments(meetingID: meetingID, segments: rows, speakers: [speaker], audioFiles: importedFiles)
                == [rows[0].id])
    }
}
