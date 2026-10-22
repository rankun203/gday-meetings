import Foundation

/// Bounded PCM checks run during processing. These checks describe signal limits;
/// they do not estimate background noise, intelligibility, or speaker overlap.
struct VoiceSampleQuality: Codable, Equatable, Sendable {
    static let policyVersion = "pcm-signal-v1"
    static let nearSilentThreshold: Float = 0.00001
    static let fullScaleThreshold: Float = 0.999
    var policy: String
    var range: VoiceSampleRange
    var audioRevision: String
    var scanConfiguration: String
    var sampleCount: Int
    var nearSilentFraction: Double
    var fullScaleFraction: Double

    enum Issue: String, Sendable {
        case shortSample, nearSilentAudio, audioAtFullScale

        var label: String {
            switch self {
            case .shortSample: "Short Sample"
            case .nearSilentAudio: "Nearly Silent Audio"
            case .audioAtFullScale: "Audio at Full Scale"
            }
        }
    }

    var issue: Issue? {
        if range.speechDuration < 2 - 1e-6 { return .shortSample }
        if nearSilentFraction >= 0.99 { return .nearSilentAudio }
        if fullScaleFraction >= 0.01 { return .audioAtFullScale }
        return nil
    }

    static let assessmentDetail =
        "Checks sample duration, nearly silent samples, and samples at full scale. "
        + "Background noise, speech clarity, and overlapping voices have not been assessed."

    static func speakerKey(track: String, label: String) -> String { track + ":" + label }

    static func assess(
        range: VoiceSampleRange, audioRevision: String, scanConfiguration: String, samples: [Float]
    ) -> Self? {
        guard range.isValid, !audioRevision.isEmpty, !scanConfiguration.isEmpty,
            !samples.isEmpty, samples.allSatisfy(\.isFinite),
            abs(Double(samples.count) / 16000 - range.speechDuration) <= 0.02
        else { return nil }
        let silent = samples.reduce(0) { $0 + (abs($1) <= nearSilentThreshold ? 1 : 0) }
        let fullScale = samples.reduce(0) { $0 + (abs($1) >= fullScaleThreshold ? 1 : 0) }
        return .init(
            policy: policyVersion, range: range, audioRevision: audioRevision,
            scanConfiguration: scanConfiguration, sampleCount: samples.count,
            nearSilentFraction: Double(silent) / Double(samples.count),
            fullScaleFraction: Double(fullScale) / Double(samples.count))
    }

    func matches(_ example: VoiceExample) -> Bool {
        policy == Self.policyVersion && range == example.range && audioRevision == example.audioRevision
            && !scanConfiguration.isEmpty && sampleCount > 0
            && nearSilentFraction.isFinite && (0...1).contains(nearSilentFraction)
            && fullScaleFraction.isFinite && (0...1).contains(fullScaleFraction)
            && abs(Double(sampleCount) / 16000 - range.speechDuration) <= 0.02
    }

    /// A measured signal problem lowers review priority. Unassessed audio remains
    /// available alongside samples with no detected PCM issue.
    static func priority(example: VoiceExample) -> Int {
        example.currentSampleQuality?.issue == nil ? 1 : 0
    }

    /// Refresh only the cheap PCM tier when cached scan ranges remain current.
    /// A quality-policy change never requires model segmentation or clustering.
    static func refresh(
        result: LocalDiarizationResult, input: VoiceDiscoveryInput,
        configuration: VoiceDiscoveryConfiguration, directory: URL,
        readSamples: @escaping @Sendable (URL, VoiceSampleRange) throws -> [Float] = { url, range in
            try LocalVoiceExampleExtractor.readSamples(url: url, spans: range.supportSpans)
        }
    ) async throws -> LocalDiarizationResult {
        let task = Task.detached(priority: .utility) {
            var refreshed = result
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            for speaker in result.speakers {
                try Task.checkCancellation()
                guard let range = speaker.voiceSampleRange, range.isValid,
                    input.audioFiles.contains(range.audioFile), let revision = input.audioRevisions[range.audioFile]
                else { continue }
                let key = speakerKey(track: speaker.track, label: speaker.label)
                let reference = VoiceExample(
                    meetingID: input.meetingID, speakerID: speaker.id, source: range.source,
                    audioFile: range.audioFile, audioRevision: revision, start: range.start, end: range.end,
                    spans: range.spans)
                if let quality = refreshed.sampleQualities?[key], quality.matches(reference) { continue }
                let url = root.appendingPathComponent(range.audioFile).standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(root.path + "/"), VoiceLibraryStore.revision(url: url) == revision else {
                    throw ServiceError("The source audio changed or is unavailable. Start a new scan.")
                }
                let samples: [Float]?
                do { samples = try readSamples(url, range) }
                catch is CancellationError { throw CancellationError() }
                catch { samples = nil }
                try Task.checkCancellation()
                guard VoiceLibraryStore.revision(url: url) == revision else {
                    throw ServiceError("The source audio changed during sample checks. Start a new scan.")
                }
                if refreshed.sampleQualities == nil { refreshed.sampleQualities = [:] }
                refreshed.sampleQualities?[key] = samples.flatMap {
                    assess(
                        range: range, audioRevision: revision, scanConfiguration: configuration.pipeline, samples: $0)
                }
            }
            return refreshed
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

extension VoiceExample {
    var currentSampleQuality: VoiceSampleQuality? {
        sampleQuality.flatMap { $0.matches(self) ? $0 : nil }
    }
}
