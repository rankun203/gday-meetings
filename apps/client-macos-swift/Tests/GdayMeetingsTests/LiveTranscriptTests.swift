import AVFoundation
import Testing

@testable import GdayMeetings

struct LiveTranscriptTests {
    @Test func testReplacementKeepsOtherSourceAndSession() {
        let session = UUID()
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.accept(.init(session: session, source: .microphone, start: 1, end: 2, text: "first"))
        draft.accept(.init(session: session, source: .system, start: 1, end: 2, text: "remote"))
        draft.accept(.init(session: session, source: .microphone, start: 1, end: 3, text: "replacement"))
        #expect(draft.phrases.map(\.text).sorted() == ["remote", "replacement"])
        draft.accept(.init(session: UUID(), source: .microphone, start: 4, end: 5, text: "after restart"))
        #expect(draft.phrases.count == 3)
        draft.accept(.init(session: session, source: .microphone, start: .nan, end: 8, text: "invalid"))
        #expect(draft.phrases.count == 3)
    }

    @Test func testBoundedQueueOwnsSamplesAndReportsDroppedRange() async throws {
        let queue = LiveAudioQueue()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0][0] = 0.25
        queue.append(buffer, start: 0)
        queue.append(buffer, start: 1)
        queue.append(buffer, start: 2)
        queue.append(buffer, start: 3)
        buffer.floatChannelData![0][0] = 0.75
        let ranges = queue.takeDroppedRanges()
        #expect(ranges.count == 1)
        #expect(ranges.first?.start == 2)
        #expect(ranges.first?.end == 4)
        #expect(queue.takeDroppedRanges().isEmpty)
        var iterator = queue.stream.makeAsyncIterator()
        let first = await iterator.next()!
        #expect(first.buffer.floatChannelData![0][0] == 0.25)
        queue.consumed(first)
        queue.append(buffer, start: 4)
        #expect(queue.takeDroppedRanges().isEmpty)
        queue.finish()
        queue.append(buffer, start: 5)
    }

    @Test func testCheckpointAndRevisionPreserveTextTimingAndSpeakers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        var draft = LiveTranscriptDraft(meetingID: id, locale: "zh-CN")
        draft.accept(
            .init(
                session: UUID(), source: .microphone, start: 1, end: 3, text: "你好 world",
                words: [.init(text: "你好", start: 1, end: 2)], locale: "zh-CN"))
        try draft.save(at: directory)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id) == draft)
        #expect(throws: (any Error).self) { try LiveTranscriptDraft.read(at: directory, meetingID: UUID()) }
        var meeting = Meeting(id: id)
        meeting.transcript = draft.segments
        meeting.speakers = [.init(label: "one", track: "mic", providerName: "RunPod")]
        try TranscriptRevisions.preserve(meeting, at: directory)
        try TranscriptRevisions.preserve(meeting, at: directory)
        let revisions = try TranscriptRevisions.read(at: directory).revisions
        #expect(revisions.count == 1)
        #expect(revisions[0].speakers == meeting.speakers)
        let mode =
            try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("live-transcript.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func testAlignedFeedDoesNotIncludePaddingAndTrimsOverlap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        var intervals: [(Double, Int)] = []
        let writer = try TimedAudioWriter(
            url: directory.appendingPathComponent("mic.wav"), format: format, epoch: 10,
            alignedAudio: { intervals.append(($1, Int($0.frameLength))) })
        try writer.append(buffer, hostSeconds: 10.2)
        try writer.append(buffer, hostSeconds: 10.25)
        try writer.finish(throughHostSeconds: 10.5)
        #expect(intervals.count == 2)
        #expect(abs(intervals[0].0 - 0.2) < 0.001)
        #expect(abs(intervals[1].0 - 0.3) < 0.001)
        #expect(intervals[1].1 == 800)
    }

    @Test func testOldSettingsDefaultToLiveTranscript() throws {
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).showLiveTranscript)
    }
    @Test func recordingSummaryUsesSemanticAvailability() {
        let fallback = RecordingMicrophoneStatus(
            voiceProcessing: true, notices: ["USB microphone unavailable · Using Built-in Microphone"])
        #expect(
            RecordingSettingsDisclosure.settingsSummary(
                language: "English", microphoneEnabled: true,
                microphone: fallback, tags: ["Planning", "Release"])
                == "English · Voice Processing On · Planning, Release")
        var unavailable = fallback
        unavailable.voiceProcessingUnavailable = true
        #expect(
            RecordingSettingsDisclosure.settingsSummary(
                language: "English", microphoneEnabled: true,
                microphone: unavailable, tags: []
            ).contains("Voice Processing Unavailable · No Tags"))
        #expect(
            RecordingSettingsDisclosure.settingsSummary(
                language: "English", microphoneEnabled: false,
                microphone: fallback, tags: []
            ).contains("Microphone Off"))
    }

    @Test @MainActor func emptyDisabledDraftIsIncomplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveTranscriptController()
        let id = UUID()
        controller.begin(
            meetingID: id, language: "en", directory: directory, sources: [.microphone],
            sink: LiveAudioSink(), enabled: false)
        await controller.finish()
        #expect(controller.draft?.complete == false)
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: id)?.phrases.isEmpty == true)
    }

    @Test @MainActor func failedRevisionSaveLeavesExistingTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        var meeting = Meeting()
        meeting.transcript = [.init(text: "Original")]
        try store.insertImportedMeeting(meeting)
        try Data("broken".utf8).write(
            to: store.directory(for: meeting.id).appendingPathComponent("transcript-revisions.json"))
        store.restoreTranscript(
            .init(title: "Other", segments: [.init(text: "Replacement")], speakers: []), meetingID: meeting.id)
        #expect(store.meetings.first?.transcript.first?.text == "Original")
        #expect(store.errorMessage != nil)
    }
    @Test @MainActor func inactiveCaptureTracksSourceBoundariesAndPersistsUncoveredAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = LiveAudioSink()
        let controller = LiveTranscriptController()
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory,
            sources: [.microphone, .system], sink: sink, enabled: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        sink.append(buffer, start: 10, source: .microphone)
        sink.append(buffer, start: 9, source: .system)
        let restartBoundaries = sink.positions()
        sink.append(buffer, start: 12, source: .microphone)
        #expect(restartBoundaries[.microphone] == 10.1)
        #expect(restartBoundaries[.system] == 9.1)
        #expect(sink.positions()[.microphone] == 12.1)
        await controller.finish()
        #expect(controller.draft?.gaps.count == 2)
        #expect(controller.draft?.gaps.first { $0.source == .microphone }?.end == 12.1)
        #expect(controller.draft?.complete == false)
    }
    @Test @MainActor func stopRetainsDetachedSessionFinalPhrase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LiveTranscriptController()
        let meetingID = UUID()
        controller.begin(
            meetingID: meetingID, language: "en", directory: directory,
            sources: [.microphone], sink: LiveAudioSink(), enabled: false)
        let token = UUID()
        controller.finalizeDetachedSession(
            token: token,
            work: {
                try? await Task.sleep(for: .milliseconds(30))
                controller.receive(
                    .init(
                        session: UUID(), source: .microphone, start: 1,
                        end: 2, text: " \tLast  phrase\n",
                        words: [.init(text: " phrase", start: 1.5, end: 2)]), final: true, token: token)
                return true
            }, cancel: nil)
        await controller.finish()
        #expect(controller.draft?.phrases.last?.text == "Last  phrase")
        #expect(try LiveTranscriptDraft.read(at: directory, meetingID: meetingID)?.phrases.last?.text == "Last  phrase")
        let phrase = try #require(controller.draft?.phrases.last)
        #expect(phrase.words == [.init(text: " phrase", start: 1.5, end: 2)])
        let highlighted = try #require(LiveTranscriptPresentation.newestWordRange(in: phrase))
        #expect(String(phrase.text[highlighted]) == "phrase")
        controller.receive(
            .init(
                session: UUID(), source: .microphone, start: 3,
                end: 4, text: "Too late"), final: true, token: token)
        #expect(controller.draft?.phrases.count == 1)
    }

}
