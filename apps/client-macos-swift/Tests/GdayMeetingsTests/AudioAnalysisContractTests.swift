import Foundation
import Testing

@testable import GdayMeetings

struct AudioAnalysisContractTests {
    private func request() -> AudioAnalysisRequest {
        .init(
            requestID: UUID(), providerID: UUID(), model: "synthetic-v1",
            audio: [.init(trackID: "track0", source: "microphone", revision: "audio-v1")])
    }

    @Test func capabilitiesDoNotAdvertiseUnimplementedAlignmentOrStandaloneRemoteDiarization() throws {
        let request = request()
        try AudioAnalysisCapabilities.apple.validate(.init(context: request, language: "en"))
        #expect(throws: AudioAnalysisContractError.unsupportedCapability) {
            try AudioAnalysisCapabilities.remoteWorker.validate(request, capability: .recordedDiarization)
        }
        #expect(throws: AudioAnalysisContractError.unsupportedCapability) {
            try AudioAnalysisCapabilities.apple.validate(request, capability: .alignment)
        }
        #expect(throws: AudioAnalysisContractError.unsupportedCapability) {
            try AudioAnalysisCapabilities.community.validate(
                .init(context: request, minimumSpeakers: 2, maximumSpeakers: 4))
        }
    }

    @Test func invalidIdentityAndClockAreRejected() {
        var request = request()
        request.audio.append(request.audio[0])
        #expect(throws: AudioAnalysisContractError.invalidRequest) {
            try AudioAnalysisCapabilities.apple.validate(request, capability: .recordedTranscription)
        }
        request.audio.removeLast()
        request.audio[0].recordingOffset = .nan
        #expect(throws: AudioAnalysisContractError.invalidRequest) {
            try AudioAnalysisCapabilities.apple.validate(request, capability: .recordedTranscription)
        }
    }

    @Test func streamDeduplicatesAndRequiresGapAndExplicitEpoch() throws {
        let session = UUID()
        let epoch = UUID()
        let item = UUID()
        var validator = AudioAnalysisStreamValidator(sessionID: session, epoch: epoch)
        var event = AudioAnalysisStreamRevision(
            sessionID: session, epoch: epoch, sequence: 0,
            itemID: item, revision: 1, finality: .provisional, payload: "First")
        #expect(try validator.accept(event))
        #expect(try !validator.accept(event))
        event.sequence = 2
        event.revision = 2
        #expect(throws: AudioAnalysisContractError.invalidStreamRevision) { try validator.accept(event) }
        try validator.recordGap(throughSequence: 1)
        event.finality = .final
        #expect(try validator.accept(event))
        event.sequence = 3
        event.revision = 3
        #expect(throws: AudioAnalysisContractError.invalidStreamRevision) { try validator.accept(event) }
        event.epoch = UUID()
        event.sequence = 0
        #expect(throws: AudioAnalysisContractError.invalidStreamRevision) { try validator.accept(event) }
        try validator.beginEpoch(event.epoch)
        #expect(try validator.accept(event))
    }

    @Test func normalizedOutputRejectsNonfiniteTimes() {
        let input = TranscriptionAnalysisRequest(context: request(), language: "en")
        #expect(throws: AudioAnalysisContractError.invalidOutput) {
            try AudioAnalysisBoundary.transcription(
                request: input, providerName: "Synthetic", segments: [.init(start: .nan, text: "Text")], speakers: [])
        }
    }

    @Test func normalizedOutputRejectsForeignTracksDuplicateIDsAndAppEdits() throws {
        let input = TranscriptionAnalysisRequest(context: request(), language: "en")
        var row = TranscriptSegment(start: 0, end: 1, text: "Text")
        row.analysisTrackID = "track0"
        _ = try AudioAnalysisBoundary.transcription(
            request: input, providerName: "Synthetic", segments: [row], speakers: [])
        #expect(throws: AudioAnalysisContractError.invalidOutput) {
            try AudioAnalysisBoundary.transcription(
                request: input, providerName: "Synthetic", segments: [row, row], speakers: [])
        }
        row.analysisTrackID = "foreign"
        #expect(throws: AudioAnalysisContractError.invalidOutput) {
            try AudioAnalysisBoundary.transcription(
                request: input, providerName: "Synthetic", segments: [row], speakers: [])
        }
        row.analysisTrackID = "track0"
        row.personID = UUID()
        #expect(throws: AudioAnalysisContractError.invalidOutput) {
            try AudioAnalysisBoundary.transcription(
                request: input, providerName: "Synthetic", segments: [row], speakers: [])
        }
        row.personID = nil
        row.timing = .init(
            text: "Text", spans: [.init(range: .init(location: 0, length: 4), start: 0, end: 2, granularity: .word)])
        #expect(throws: AudioAnalysisContractError.invalidOutput) {
            try AudioAnalysisBoundary.transcription(
                request: input, providerName: "Synthetic", segments: [row], speakers: [])
        }
    }

    @Test func acousticConversionRetainsStableIdentitiesAndUncertainty() {
        let context = request()
        let analysis = RecordedDiarizationAnalysis(
            acoustic: .init(
                id: UUID(),
                provenance: .init(requestID: context.requestID, providerName: "Synthetic", audio: context.audio),
                turns: [.init(trackID: "track0", speakerID: "speaker0", start: 0, end: 1, associationUncertain: true)]),
            speakers: [.init(trackID: "track0", speakerID: "speaker0")], generatedAt: Date(),
            unresolvedRanges: [.init(trackID: "track0", start: 1, end: 2)], detail: "Unassigned speech")
        let first = analysis.localResult()
        let second = analysis.localResult()
        #expect(first.speakers == second.speakers)
        #expect(first.ranges[0].associationUncertain == true)
        #expect(first.unresolvedRanges?.first?.start == 1)
        #expect(first.detail == "Unassigned speech")
    }
}
