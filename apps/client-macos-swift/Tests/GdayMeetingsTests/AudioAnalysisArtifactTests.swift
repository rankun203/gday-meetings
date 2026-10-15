import Foundation
import Testing

@testable import GdayMeetings

struct AudioAnalysisArtifactTests {
    @Test func admissionUsesSupportedProviderOptionsAndRetainsExactRequest() throws {
        let audio = [AnalysisAudioReference(trackID: "track0", source: "system", revision: "synthetic")]
        for (kind, diarize) in [(ServiceProviderKind.appleSpeech, false), (.runpod, false), (.runpod, true)] {
            let provider = ServiceProvider(kind: kind)
            var attempt = ProviderTranscriptionAttempt(provider: provider, meeting: Meeting())
            try attempt.admit(provider: provider, audio: audio, diarize: diarize)
            let request = try #require(attempt.analysisRequest)
            #expect(request.context.options["diarize"] == String(diarize))
            #expect(request.context.audio == audio)
            #expect(attempt.diarize == diarize)
            #expect(attempt.admittedAt != nil)
            let roundTrip = try JSONDecoder().decode(
                ProviderTranscriptionAttempt.self, from: JSONEncoder().encode(attempt))
            #expect(roundTrip.analysisRequest == request)
            let capabilities: AudioAnalysisCapabilities = kind == .appleSpeech ? .apple : .remoteWorker
            try capabilities.validate(try #require(roundTrip.analysisRequest))
        }
        let apple = ServiceProvider(kind: .appleSpeech)
        var invalid = ProviderTranscriptionAttempt(provider: apple, meeting: Meeting())
        #expect(throws: AudioAnalysisContractError.unsupportedCapability) {
            try invalid.admit(provider: apple, audio: audio, diarize: true)
        }
        #expect(invalid.analysisRequest == nil)
        #expect(invalid.admittedAt == nil)
        #expect(AudioAnalysisContractError.unsupportedCapability.errorDescription?.contains("provider") == true)
    }

    @Test func draftAttemptDoesNotClaimAnAdmittedAudioSnapshot() {
        let attempt = ProviderTranscriptionAttempt(provider: ServiceProvider(kind: .appleSpeech), meeting: Meeting())
        #expect(attempt.analysisRequest == nil)
        #expect(attempt.audioReferences == nil)
        #expect(attempt.admittedAt == nil)
    }

    @Test func immutableSourceKeepsOriginalTextAndRejectsChangedAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var meeting = Meeting()
        meeting.transcript = [.init(text: "Original text")]
        let audio = [AnalysisAudioReference(trackID: "track0", source: "system", revision: "first")]
        let artifact = try #require(
            try AudioAnalysisArtifacts.source(meeting: meeting, audio: audio, directory: folder))
        try artifact.data.write(to: folder.appendingPathComponent(artifact.name))
        meeting.transcript[0].text = "Edited text"
        #expect(
            try AudioAnalysisArtifacts.source(meeting: meeting, audio: audio, directory: folder)?.data == artifact.data)
        let saved = try JSONDecoder().decode(TranscriptionAnalysisArtifact.self, from: artifact.data)
        #expect(saved.segments[0].text == "Original text")
        #expect(throws: (any Error).self) {
            try AudioAnalysisArtifacts.source(
                meeting: meeting,
                audio: [.init(trackID: "track0", source: "system", revision: "second")], directory: folder)
        }
    }

    @Test func projectionCompatibilityRequiresExactAnchoredTextAndTiming() {
        let rowID = UUID()
        let first = TranscriptSegment(
            start: 0, end: 1, text: "Hi",
            timing: .init(
                text: "Hi", spans: [.init(range: .init(location: 0, length: 2), start: 0, end: 1, granularity: .word)]),
            sourceSpans: [.init(rowID: rowID, range: .init(location: 0, length: 2), text: "Hi")])
        let second = TranscriptSegment(
            start: 1, end: 2, text: "!",
            timing: .init(
                text: "!", spans: [.init(range: .init(location: 0, length: 1), start: 1, end: 2, granularity: .word)]),
            sourceSpans: [.init(rowID: rowID, range: .init(location: 2, length: 1), text: "!")])
        var merged = TranscriptSegment(
            start: 0, end: 2, text: "Hi!",
            timing: .init(
                text: "Hi!",
                spans: [
                    .init(range: .init(location: 0, length: 2), start: 0, end: 1, granularity: .word),
                    .init(range: .init(location: 2, length: 1), start: 1, end: 2, granularity: .word),
                ]), sourceSpans: [.init(rowID: rowID, range: .init(location: 0, length: 3), text: "Hi!")])
        #expect(TranscriptRevisions.sameProjectionText([first, second], [merged]))
        merged.source = .system
        #expect(!TranscriptRevisions.sameProjectionText([first, second], [merged]))
        merged.source = nil
        merged.session = UUID()
        #expect(!TranscriptRevisions.sameProjectionText([first, second], [merged]))
        merged.session = nil
        merged.text = "Changed"
        #expect(!TranscriptRevisions.sameProjectionText([first, second], [merged]))
        merged.text = "Hi!"
        merged.timing?.spans[0].end = 0.9
        #expect(!TranscriptRevisions.sameProjectionText([first, second], [merged]))
        merged.timing = nil
        #expect(!TranscriptRevisions.sameProjectionText([first, second], [merged]))
    }
}
