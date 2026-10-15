import Foundation

/// Immutable input text. Later projections and edits never replace this artifact.
enum TranscriptionAudioBinding: String, Codable { case admittedInput, observedSnapshot }

struct TranscriptionAnalysisArtifact: Codable {
    var version = 1
    var source: TranscriptSource
    var audio: [AnalysisAudioReference]?
    var request: TranscriptionAnalysisRequest?
    var binding: TranscriptionAudioBinding
    var segments: [TranscriptSegment]
}

/// Binds a saved acoustic result to the input used for its transcript projection.
struct DiarizationProjectionArtifact: Codable {
    var version = 1
    var sourceID: UUID
    var resultID: UUID
    var audio: [AnalysisAudioReference]
}

enum AudioAnalysisArtifacts {
    static func audio(files: [URL], revisions: [URL: String]) -> [AnalysisAudioReference] {
        files.enumerated().compactMap { index, file in
            revisions[file].map {
                AnalysisAudioReference(
                    trackID: "track\(index)", source: LocalDiarizationInputPolicy.sourceName(for: file), revision: $0)
            }
        }
    }

    static func immutable<T: Encodable>(
        _ value: T, name: String, meetingID: UUID, directory: URL
    ) throws -> CanonicalMeetingArtifact {
        try PrivateTranscriptFile.validatePath(name: name, at: directory)
        let url = directory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        if let previous, previous != data {
            throw ServiceError("The saved analysis has different content. Run the analysis again.")
        }
        return .init(meetingID: meetingID, name: name, data: data, previous: previous)
    }

    static func source(
        meeting: Meeting, audio: [AnalysisAudioReference]?, directory: URL,
        binding: TranscriptionAudioBinding = .observedSnapshot, request: TranscriptionAnalysisRequest? = nil
    ) throws -> CanonicalMeetingArtifact? {
        let source =
            meeting.transcriptSource
            ?? TranscriptSource(id: meeting.id, providerName: "Transcript", generatedAt: meeting.createdAt)
        let name = "transcription-source-\(source.id).json"
        try PrivateTranscriptFile.validatePath(name: name, at: directory)
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            let saved = try JSONDecoder().decode(TranscriptionAnalysisArtifact.self, from: bytes)
            try validate(saved)
            guard saved.version == 1, saved.source.id == source.id,
                saved.audio == nil || saved.audio == audio,
                Set(saved.segments.map(\.id)).count == saved.segments.count,
                saved.segments.allSatisfy({ row in
                    row.start.isFinite && row.end.isFinite && row.start >= 0 && row.end >= row.start
                        && (row.timing == nil || (row.timing?.text == row.text && row.timing?.isValid == true))
                })
            else {
                throw ServiceError(
                    "The source audio changed. Transcribe the current recording before labeling speakers.")
            }
            return .init(meetingID: meeting.id, name: name, data: bytes, previous: bytes)
        }
        let value = TranscriptionAnalysisArtifact(
            source: source, audio: audio, request: request, binding: binding, segments: meeting.transcript)
        try validate(value)
        return try immutable(value, name: name, meetingID: meeting.id, directory: directory)
    }

    static func validate(_ value: TranscriptionAnalysisArtifact) throws {
        if let audio = value.audio {
            guard Set(audio.map(\.trackID)).count == audio.count,
                audio.allSatisfy({
                    !$0.trackID.isEmpty && !$0.revision.isEmpty
                        && $0.recordingOffset.isFinite && $0.recordingOffset >= 0
                })
            else { throw AudioAnalysisContractError.invalidRequest }
        }
        if let request = value.request {
            try AudioAnalysisCapabilities.remoteWorker.validate(request)
            guard request.context.audio == value.audio, request.context.requestID == value.source.id else {
                throw AudioAnalysisContractError.invalidRequest
            }
        }
    }

    static func history(meeting: Meeting, directory: URL) throws -> CanonicalMeetingArtifact? {
        let name = "transcript-revisions.json"
        try PrivateTranscriptFile.validatePath(name: name, at: directory)
        let url = directory.appendingPathComponent(name)
        let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard let data = try TranscriptRevisions.preserving(meeting, previous: previous) else { return nil }
        return .init(meetingID: meeting.id, name: name, data: data, previous: previous)
    }
}
