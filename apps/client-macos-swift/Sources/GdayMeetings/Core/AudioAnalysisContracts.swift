import CryptoKit
import Foundation

/// Capability contracts are independent: diarization never requires recognized text.
enum AudioAnalysisCapability: String, Codable, Sendable {
    case recordedTranscription, liveTranscription, recordedDiarization, liveDiarization, alignment
}

struct AnalysisAudioReference: Codable, Equatable, Sendable {
    var trackID: String
    var source: String
    var revision: String
    /// Provider times are track-relative seconds. Add this offset exactly once at normalization.
    var recordingOffset: Double = 0
}

struct AudioAnalysisRequest: Codable, Equatable, Sendable {
    var version = 1
    var requestID: UUID
    var providerID: UUID
    var model: String
    var audio: [AnalysisAudioReference]
    var options: [String: String] = [:]
}

enum AudioAnalysisContractError: LocalizedError, Equatable {
    case unsupportedCapability, invalidRequest, invalidOutput, invalidStreamRevision

    var errorDescription: String? {
        switch self {
        case .unsupportedCapability:
            return
                "The selected provider doesn’t support these processing options. Choose another provider or change the options."
        case .invalidRequest:
            return
                "The processing request has invalid or missing audio information. Start a new request for this recording."
        case .invalidOutput:
            return "The provider returned invalid transcript or speaker timing. The current transcript was kept."
        case .invalidStreamRevision:
            return "The live processing update is inconsistent with the current session."
        }
    }
}

/// These describe adapter support, not model-download readiness or user-enabled settings.
struct AudioAnalysisCapabilities: Equatable, Sendable {
    var supported: Set<AudioAnalysisCapability>
    var timing: TranscriptTimingGranularity?
    var supportsSpeakerBounds = false
    var supportsTimelineOffsets = false
    var supportsCombinedDiarization = false

    static let apple = Self(supported: [.recordedTranscription, .liveTranscription], timing: .run)
    static let community = Self(supported: [.recordedDiarization], timing: nil)
    // Remote diarization is available only as part of transcription, not as a standalone request.
    static let remoteWorker = Self(
        supported: [.recordedTranscription], timing: .word, supportsCombinedDiarization: true)

    func validate(_ request: AudioAnalysisRequest, capability: AudioAnalysisCapability) throws {
        guard supported.contains(capability) else { throw AudioAnalysisContractError.unsupportedCapability }
        guard request.version == 1, !request.audio.isEmpty,
            Set(request.audio.map(\.trackID)).count == request.audio.count,
            request.audio.allSatisfy({
                !$0.trackID.isEmpty && !$0.revision.isEmpty && $0.recordingOffset.isFinite && $0.recordingOffset >= 0
            })
        else { throw AudioAnalysisContractError.invalidRequest }
        guard supportsTimelineOffsets || request.audio.allSatisfy({ $0.recordingOffset == 0 }) else {
            throw AudioAnalysisContractError.unsupportedCapability
        }
    }

    func validate(_ request: TranscriptionAnalysisRequest) throws {
        try validate(request.context, capability: .recordedTranscription)
        guard Set(request.context.options.keys).isSubset(of: ["language", "diarize"]),
            request.context.options["language"].map({ $0 == request.language }) ?? true
        else { throw AudioAnalysisContractError.unsupportedCapability }
        if let diarize = request.context.options["diarize"] {
            guard diarize == "true" || diarize == "false" else { throw AudioAnalysisContractError.invalidRequest }
            guard diarize == "false" || supportsCombinedDiarization else {
                throw AudioAnalysisContractError.unsupportedCapability
            }
        }
        guard !request.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioAnalysisContractError.invalidRequest
        }
    }

    func validate(_ request: DiarizationAnalysisRequest) throws {
        try validate(request.context, capability: .recordedDiarization)
        guard request.context.options.isEmpty else { throw AudioAnalysisContractError.unsupportedCapability }
        guard supportsSpeakerBounds || (request.minimumSpeakers == nil && request.maximumSpeakers == nil) else {
            throw AudioAnalysisContractError.unsupportedCapability
        }
        if let minimum = request.minimumSpeakers, minimum < 1 { throw AudioAnalysisContractError.invalidRequest }
        if let maximum = request.maximumSpeakers, maximum < 1 { throw AudioAnalysisContractError.invalidRequest }
        if let minimum = request.minimumSpeakers, let maximum = request.maximumSpeakers, minimum > maximum {
            throw AudioAnalysisContractError.invalidRequest
        }
    }
}

/// File locations belong to an adapter call and are not persisted in portable provenance.
struct AnalysisAudioFile: Sendable {
    var reference: AnalysisAudioReference
    var url: URL
}

struct RecordedTranscriptionAnalysis: Codable, Equatable, Sendable {
    var provenance: AudioAnalysisProvenance
    var segments: [TranscriptSegment]
    var speakers: [MeetingSpeaker]
}

protocol RecordedTranscriptionAnalysisProvider: Sendable {
    var capabilities: AudioAnalysisCapabilities { get }
    func transcribe(
        request: TranscriptionAnalysisRequest, files: [AnalysisAudioFile],
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> RecordedTranscriptionAnalysis
}

protocol RecordedDiarizationAnalysisProvider: Sendable {
    var capabilities: AudioAnalysisCapabilities { get }
    func diarize(
        request: DiarizationAnalysisRequest, files: [AnalysisAudioFile],
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> RecordedDiarizationAnalysis
}

struct AcousticSpeakerMetadata: Codable, Equatable, Sendable {
    var trackID: String
    var speakerID: String
    var voiceEmbedding: TypedVoiceEmbedding?
    var sampleRange: VoiceSampleRange?
    var sampleAudioRevision: String?
}

struct RecordedDiarizationAnalysis: Codable, Sendable {
    var acoustic: AcousticAnalysis
    var speakers: [AcousticSpeakerMetadata]
    var generatedAt: Date
    var unresolvedRanges: [AcousticUnresolvedRange]? = nil
    var detail: String? = nil

    /// App identity is created only after the provider-neutral result crosses this boundary.
    func localResult() -> LocalDiarizationResult {
        .init(
            id: acoustic.id, generatedAt: generatedAt, modelRevision: acoustic.provenance.modelRevision ?? "",
            ranges: acoustic.turns.map {
                .init(
                    track: $0.trackID, label: $0.speakerID, start: $0.start, end: $0.end,
                    associationUncertain: $0.associationUncertain)
            },
            speakers: speakers.map {
                .init(
                    id: speakerIdentity(track: $0.trackID, speaker: $0.speakerID), label: $0.speakerID,
                    track: $0.trackID,
                    providerName: acoustic.provenance.providerName,
                    voiceEmbedding: $0.voiceEmbedding, voiceSampleRange: $0.sampleRange,
                    voiceSampleRevision: $0.sampleAudioRevision)
            },
            trackSources: Dictionary(uniqueKeysWithValues: acoustic.provenance.audio.map { ($0.trackID, $0.source) }),
            detail: detail, providerName: acoustic.provenance.providerName,
            unresolvedRanges: unresolvedRanges?.map { .init(track: $0.trackID, start: $0.start, end: $0.end) },
            audioReferences: acoustic.provenance.audio)
    }

    private func speakerIdentity(track: String, speaker: String) -> UUID {
        let key = [acoustic.id.uuidString, track, speaker].map { "\($0.utf8.count):\($0)" }.joined()
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

struct AcousticUnresolvedRange: Codable, Equatable, Sendable {
    var trackID: String
    var start: Double
    var end: Double
}

enum AudioAnalysisBoundary {
    static func validateFiles(_ files: [AnalysisAudioFile], request: AudioAnalysisRequest) throws {
        guard files.map(\.reference) == request.audio,
            files.allSatisfy({ VoiceLibraryStore.revision(url: $0.url) == $0.reference.revision })
        else { throw AudioAnalysisContractError.invalidRequest }
    }

    static func transcription(
        request: TranscriptionAnalysisRequest, providerName: String,
        segments: [TranscriptSegment], speakers: [MeetingSpeaker]
    ) throws -> RecordedTranscriptionAnalysis {
        let tracks = Set(request.context.audio.map(\.trackID))
        guard Set(segments.map(\.id)).count == segments.count,
            speakers.allSatisfy({
                $0.personID == nil && $0.manuallyAssigned != true && !$0.confirmed
                    && $0.passageAssignmentOrigin == nil && $0.manualReviewThrough == nil
                    && $0.voiceReviewOrigin == nil && $0.voiceReviewExampleID == nil
            }),
            segments.allSatisfy({ row in
                row.start.isFinite && row.end.isFinite && row.start >= 0 && row.end >= row.start
                    && row.analysisTrackID.map(tracks.contains) == true
                    && row.personID == nil && row.sourceSpans == nil
                    && (row.timing == nil
                        || (row.timing?.isValid == true && row.timing?.text == row.text
                            && row.timing?.spans.allSatisfy { $0.start >= row.start && $0.end <= row.end } == true))
            })
        else { throw AudioAnalysisContractError.invalidOutput }
        return .init(
            provenance: .init(
                requestID: request.context.requestID,
                providerID: request.context.providerID, providerName: providerName,
                modelRevision: nil, audio: request.context.audio, configuredModel: request.context.model),
            segments: segments, speakers: speakers)
    }
}

struct AppleRecordedAnalysisProvider: RecordedTranscriptionAnalysisProvider {
    var capabilities: AudioAnalysisCapabilities { .apple }
    var meetingID: UUID

    func transcribe(
        request: TranscriptionAnalysisRequest, files: [AnalysisAudioFile],
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> RecordedTranscriptionAnalysis {
        try capabilities.validate(request)
        try AudioAnalysisBoundary.validateFiles(files, request: request.context)
        var segments: [TranscriptSegment] = []
        var speakers: [MeetingSpeaker] = []
        for file in files {
            let draft = try await AppleRecordedTranscription.transcribe(
                files: [file.url], meetingID: meetingID, language: request.language, status: progress)
            segments += draft.segments.map { row in
                var row = row
                row.analysisTrackID = file.reference.trackID
                return row
            }
            speakers += draft.speakers
        }
        try AudioAnalysisBoundary.validateFiles(files, request: request.context)
        return try AudioAnalysisBoundary.transcription(
            request: request, providerName: "This Mac",
            segments: segments.sorted { $0.start < $1.start }, speakers: speakers)
    }
}

struct CommunityRecordedAnalysisProvider: RecordedDiarizationAnalysisProvider {
    var capabilities: AudioAnalysisCapabilities { .community }
    var lease: LocalModelLease
    var extractVoiceEmbeddings: Bool

    func diarize(
        request: DiarizationAnalysisRequest, files: [AnalysisAudioFile],
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> RecordedDiarizationAnalysis {
        try capabilities.validate(request)
        guard request.context.model == lease.revision else { throw AudioAnalysisContractError.invalidRequest }
        try AudioAnalysisBoundary.validateFiles(files, request: request.context)
        let result = try await CommunityDiarizationWorker().run(
            files: files.map(\.url), lease: lease, recognize: extractVoiceEmbeddings, progress: progress)
        try AudioAnalysisBoundary.validateFiles(files, request: request.context)
        var acoustic = result.acousticAnalysis
        acoustic.provenance.requestID = request.context.requestID
        acoustic.provenance.providerID = request.context.providerID
        acoustic.provenance.audio = request.context.audio
        let tracks = Dictionary(
            uniqueKeysWithValues: files.enumerated().map { ("track\($0.offset)", $0.element.reference.trackID) })
        acoustic.turns = try acoustic.turns.map { turn in
            guard let track = tracks[turn.trackID], turn.start.isFinite, turn.end.isFinite,
                turn.start >= 0, turn.end > turn.start
            else { throw AudioAnalysisContractError.invalidOutput }
            var turn = turn
            turn.trackID = track
            return turn
        }
        return .init(
            acoustic: acoustic,
            speakers: result.speakers.map {
                .init(
                    trackID: tracks[$0.track] ?? $0.track, speakerID: $0.label, voiceEmbedding: $0.voiceEmbedding,
                    sampleRange: $0.voiceSampleRange, sampleAudioRevision: $0.voiceSampleRevision)
            }, generatedAt: result.generatedAt,
            unresolvedRanges: result.unresolvedRanges?.map {
                .init(trackID: tracks[$0.track] ?? $0.track, start: $0.start, end: $0.end)
            }, detail: result.detail)
    }
}

struct TranscriptionAnalysisRequest: Codable, Equatable, Sendable {
    var context: AudioAnalysisRequest
    var language: String
}

struct DiarizationAnalysisRequest: Codable, Equatable, Sendable {
    var context: AudioAnalysisRequest
    var minimumSpeakers: Int?
    var maximumSpeakers: Int?
}

struct AlignmentAnalysisRequest: Codable, Equatable, Sendable {
    var context: AudioAnalysisRequest
    var transcriptRevisionID: UUID
    var language: String
}

struct AudioAnalysisProvenance: Codable, Equatable, Sendable {
    var version = 1
    var requestID: UUID
    var providerID: UUID?
    var providerName: String
    var modelRevision: String?
    var audio: [AnalysisAudioReference]
    var configuredModel: String? = nil
}

/// Finality is per revision domain: finalized text does not finalize acoustic identities.
enum AudioAnalysisFinality: String, Codable, Sendable { case provisional, final }

struct AudioAnalysisStreamRevision<Payload: Codable & Sendable>: Codable, Sendable {
    var version = 1
    var sessionID: UUID
    var epoch: UUID
    var sequence: UInt64
    var itemID: UUID
    var revision: UInt64
    var finality: AudioAnalysisFinality
    var payload: Payload
}

/// A stream restart requires an explicit epoch transition; skipped sequence numbers require a gap.
struct AudioAnalysisStreamValidator: Sendable {
    let sessionID: UUID
    private(set) var epoch: UUID
    private var nextSequence: UInt64 = 0
    private var revisions: [UUID: (revision: UInt64, final: Bool)] = [:]
    private var previousEpochs: Set<UUID> = []

    init(sessionID: UUID, epoch: UUID) {
        self.sessionID = sessionID
        self.epoch = epoch
    }

    mutating func accept<Payload>(_ event: AudioAnalysisStreamRevision<Payload>) throws -> Bool {
        guard event.version == 1, event.sessionID == sessionID, event.epoch == epoch else {
            throw AudioAnalysisContractError.invalidStreamRevision
        }
        if event.sequence < nextSequence { return false }
        guard event.sequence == nextSequence, nextSequence < UInt64.max else {
            throw AudioAnalysisContractError.invalidStreamRevision
        }
        if let previous = revisions[event.itemID] {
            guard !previous.final, event.revision > previous.revision else {
                throw AudioAnalysisContractError.invalidStreamRevision
            }
        }
        revisions[event.itemID] = (event.revision, event.finality == .final)
        nextSequence += 1
        return true
    }

    mutating func recordGap(throughSequence: UInt64) throws {
        guard throughSequence >= nextSequence, throughSequence < UInt64.max else {
            throw AudioAnalysisContractError.invalidStreamRevision
        }
        nextSequence = throughSequence + 1
    }

    mutating func beginEpoch(_ replacement: UUID) throws {
        guard replacement != epoch, !previousEpochs.contains(replacement) else {
            throw AudioAnalysisContractError.invalidStreamRevision
        }
        previousEpochs.insert(epoch)
        epoch = replacement
        nextSequence = 0
        revisions = [:]
    }
}

struct AcousticSpeakerTurn: Codable, Equatable, Sendable {
    var trackID: String
    /// Scoped to the analysis result and track; never a People identifier.
    var speakerID: String
    var start: Double
    var end: Double
    var associationUncertain: Bool? = nil
}

struct AcousticAnalysis: Codable, Equatable, Sendable {
    var version = 1
    var id: UUID
    var provenance: AudioAnalysisProvenance
    var turns: [AcousticSpeakerTurn]
}

extension LocalDiarizationResult {
    var acousticAnalysis: AcousticAnalysis {
        .init(
            id: id,
            provenance: .init(
                requestID: id, providerName: providerName ?? "Community-1",
                modelRevision: modelRevision, audio: audioReferences ?? []),
            turns: ranges.map {
                .init(
                    trackID: $0.track, speakerID: $0.label, start: $0.start, end: $0.end,
                    associationUncertain: $0.associationUncertain)
            })
    }
}
