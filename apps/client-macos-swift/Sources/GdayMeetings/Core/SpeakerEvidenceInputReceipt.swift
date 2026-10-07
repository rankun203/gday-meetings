import Foundation

/// Bind a drained journal to finalized audio, including recording-format conversion.
struct SpeakerEvidenceInputReceipt: Codable, Equatable, Sendable {
    var version = 1
    var audioRevisions: [String: String]
    var evidenceRevision: String
    static let fileName = "speaker-evidence-source.json"

    /// The measured threshold belongs to this encoder contract and explicit window policy.
    /// Unknown provenance or a different encoder uses the saved-audio labeling path.
    static func isConsolidatable(_ evidence: SpeakerEvidenceDocument) -> Bool {
        guard !evidence.samples.isEmpty,
            evidence.samples.allSatisfy({ $0.model == .community1SpeechSpan })
        else { return false }
        return evidence.samples.contains { sample in
            sample.embedding.isValid && sample.start.isFinite && sample.end.isFinite
                && sample.end > sample.start
                && (evidence.windows ?? []).contains { window in
                    window.source == sample.source && window.localSpeakerIDs.contains(sample.localSpeakerID)
                        && sample.start >= window.publicationStart
                        && window.trustedEnd.map { sample.end <= $0 } == true
                }
                && evidence.activity.contains {
                    $0.source == sample.source && $0.localSpeakerID == sample.localSpeakerID
                        && $0.start < sample.end && $0.end > sample.start
                }
        }
    }

    static func hasConsolidationEvidence(directory: URL, files: [URL]) throws -> Bool {
        try validate(directory: directory, files: files)
        return isConsolidatable(try SpeakerEvidenceStore.read(directory: directory))
    }

    static func seal(directory: URL, files: [URL]) throws {
        guard try SpeakerEvidenceStore.isComplete(directory: directory),
            let evidenceRevision = VoiceLibraryStore.revision(
                url: directory.appendingPathComponent(SpeakerEvidenceStore.fileName))
        else {
            throw ServiceError("Speaker evidence did not finish saving. Use Label Speakers to analyze saved audio.")
        }
        let revisions = try LocalDiarizationInputPolicy.revisions(for: files)
        let receipt = Self(
            audioRevisions: Dictionary(uniqueKeysWithValues: revisions.map { ($0.key.lastPathComponent, $0.value) }),
            evidenceRevision: evidenceRevision)
        try PrivateTranscriptFile.write(try JSONEncoder().encode(receipt), name: fileName, at: directory)
    }

    @discardableResult
    static func validate(directory: URL, files: [URL], expected: Self? = nil) throws -> Self {
        try PrivateTranscriptFile.validatePath(name: fileName, at: directory)
        let receipt = try JSONDecoder().decode(
            Self.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
        let revisions = try LocalDiarizationInputPolicy.revisions(for: files)
        guard expected == nil || expected == receipt,
            receipt.version == 1, try SpeakerEvidenceStore.isComplete(directory: directory),
            receipt.evidenceRevision
                == VoiceLibraryStore.revision(
                    url: directory.appendingPathComponent(SpeakerEvidenceStore.fileName)),
            receipt.audioRevisions
                == Dictionary(uniqueKeysWithValues: revisions.map { ($0.key.lastPathComponent, $0.value) })
        else {
            throw ServiceError(
                "The recording or speaker evidence changed. Use Label Speakers to analyze the current audio.")
        }
        return receipt
    }
}
