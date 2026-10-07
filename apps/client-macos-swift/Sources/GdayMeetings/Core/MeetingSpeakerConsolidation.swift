import CryptoKit
import Foundation

/// Acoustic regrouping is separate from person decisions. Existing explicit
/// assignments remain authoritative; a new group does not inherit a name by slot.
enum MeetingSpeakerConsolidation {
    static let revision = SpeakerConsolidation.revision

    static func labeling(
        _ result: SpeakerConsolidationResult, evidence: SpeakerEvidenceDocument, meeting: Meeting
    ) -> LocalDiarizationResult {
        let samples = Dictionary(evidence.samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var speakers: [MeetingSpeaker] = []
        var ranges: [LocalSpeakerRange] = []
        var reservedLabels = Set(meeting.speakers.map(\.label))
        var publishedLabels = Set<String>()
        for cluster in result.clusters {
            guard let sample = cluster.representativeSampleIDs.compactMap({ samples[$0] }).first else { continue }
            let source = Set(cluster.sampleIDs.compactMap { samples[$0]?.source })
            let track = source.count == 1 ? source.first! : "multiple"
            let id = speakerIdentity(cluster: cluster, result: result, evidence: evidence, meeting: meeting)
            let existing = meeting.speakers.first { $0.id == id }
            var label = existing?.label ?? ""
            if label.isEmpty || publishedLabels.contains(label) {
                var number = 1
                while reservedLabels.contains("Speaker \(number)") { number += 1 }
                label = "Speaker \(number)"
            }
            reservedLabels.insert(label)
            publishedLabels.insert(label)
            var speaker =
                existing
                ?? MeetingSpeaker(
                    id: id, label: label, track: track, providerName: "Speaker Consolidation",
                    voiceEmbedding: sample.embedding)
            speaker.label = label
            speaker.voiceEmbedding = sample.embedding
            if let file = meeting.audioFiles.first(where: {
                LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == sample.source
            }) {
                speaker.voiceSampleRange = .init(
                    audioFile: file, source: sample.source, start: sample.start, end: sample.end)
            }
            speakers.append(speaker)
            ranges += result.intervals.filter { $0.clusterID == cluster.id }.map {
                .init(track: $0.source, label: speaker.label, start: $0.start, end: $0.end)
            }
        }
        return .init(
            modelRevision: revision, ranges: ranges, speakers: speakers, providerName: "Speaker Consolidation",
            unresolvedRanges: result.intervals.filter { $0.clusterID == nil }.map {
                .init(track: $0.source, start: $0.start, end: $0.end)
            })
    }

    static func applying(_ result: LocalDiarizationResult, to meeting: Meeting) -> Meeting {
        var updated = meeting
        let original = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0) })
        let replacements = Dictionary(result.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var speakers = meeting.speakers.map { old in
            guard var replacement = replacements[old.id] else { return old }
            if old.manuallyAssigned == true {
                replacement.label = old.label
                replacement.personID = old.personID
                replacement.manuallyAssigned = old.manuallyAssigned
                replacement.confirmed = old.confirmed
                replacement.confidence = old.confidence
            }
            return replacement
        }
        for index in updated.transcript.indices {
            let row = updated.transcript[index]
            let old = row.speakerID.flatMap { original[$0] }
            // Explicit corrections, including an explicit removal, survive regrouping.
            guard old?.manuallyAssigned != true, row.end > row.start else { continue }
            let source = row.source?.rawValue ?? normalizedSource(old?.track)
            guard let source else { continue }
            // A dominant safe portion does not identify the rest of a transcript row.
            // Keep the prior label when any speech in this source remains unresolved.
            guard
                !(result.unresolvedRanges ?? []).contains(where: {
                    $0.track == source && $0.start < row.end && $0.end > row.start
                })
            else { continue }
            let activity = result.ranges.filter {
                $0.track == source && $0.start < row.end && $0.end > row.start
            }
            var durations: [String: Double] = [:]
            for (label, spans) in Dictionary(grouping: activity, by: \.label) {
                var end = row.start
                for interval in spans.sorted(by: { $0.start < $1.start }) {
                    let lower = max(end, max(row.start, interval.start))
                    let upper = min(row.end, interval.end)
                    durations[label, default: 0] += max(0, upper - lower)
                    end = max(end, upper)
                }
            }
            let ranked = durations.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard let best = ranked.first, best.value >= (row.end - row.start) * 0.6,
                ranked.dropFirst().allSatisfy({ $0.value < best.value * 0.25 }),
                let speaker = result.speakers.first(where: {
                    $0.label == best.key && (normalizedSource($0.track) == source || $0.track == "multiple")
                })
            else { continue }
            if !speakers.contains(where: { $0.id == speaker.id }) { speakers.append(speaker) }
            updated.transcript[index].speakerID = speaker.id
            updated.transcript[index].speaker = speaker.label
            updated.transcript[index].personID = speaker.personID
            if row.speakerID != speaker.id || row.sourcePlaceholder == true {
                updated.transcript[index].sourcePlaceholder = false
            }
        }
        let used = Set(updated.transcript.compactMap(\.speakerID))
        updated.replaceSpeakers(speakers.filter { used.contains($0.id) })
        return updated
    }

    static func speakerIdentity(
        cluster: SpeakerConsolidationResult.Cluster, result: SpeakerConsolidationResult,
        evidence: SpeakerEvidenceDocument, meeting: Meeting
    ) -> UUID {
        let members = Set(cluster.sampleIDs)
        let samples = evidence.samples.filter { members.contains($0.id) }
        let locals = Set(samples.map(\.localSpeakerID))
        let sources = Set(samples.map(\.source))
        if locals.count == 1, sources.count == 1, let local = locals.first,
            let source = sources.first, let id = UUID(uuidString: local),
            meeting.speakers.contains(where: { $0.id == id }),
            result.intervals.contains(where: { $0.source == source && $0.localSpeakerID == local }),
            result.intervals.filter({ $0.source == source && $0.localSpeakerID == local })
                .allSatisfy({ $0.clusterID == cluster.id })
        {
            return id
        }
        return identity(meetingID: meeting.id, clusterID: cluster.id)
    }

    static func identity(meetingID: UUID, clusterID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(meetingID)|\(revision)|\(clusterID)".utf8)).prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    private static func normalizedSource(_ track: String?) -> String? {
        switch track {
        case "microphone", "mic": return "microphone"
        case "system", "system_mix": return "system"
        default: return nil
        }
    }
}

extension MeetingStore {
    func performSpeakerConsolidation(id: UUID) async throws {
        guard libraryWritable, recordingID != id, let original = meeting(id: id),
            original.transcriptionAttempt == nil, !isJobRunning(.transcription, .meeting(id))
        else { throw ServiceError("Wait for transcription to finish before consolidating speakers.") }
        let folder = directory(for: id)
        let files = audioURLs(for: original)
        let revisions = try LocalDiarizationInputPolicy.revisions(for: files)
        setJobProgress(.diarization, .meeting(id), "Consolidating speakers…")
        let operation = Task.detached(priority: .utility) {
            let inputReceipt = try SpeakerEvidenceInputReceipt.validate(directory: folder, files: files)
            let evidence = try SpeakerEvidenceStore.read(directory: folder)
            try Task.checkCancellation()
            guard SpeakerEvidenceInputReceipt.isConsolidatable(evidence) else {
                throw ServiceError(
                    "Retained voice evidence is not supported for consolidation. Use Analyze Recording to label speakers."
                )
            }
            let result = try SpeakerConsolidation.run(evidence) { try Task.checkCancellation() }
            try SpeakerEvidenceInputReceipt.validate(directory: folder, files: files, expected: inputReceipt)
            return (evidence, result, inputReceipt)
        }
        let analysis = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        var result = MeetingSpeakerConsolidation.labeling(analysis.1.result, evidence: analysis.0, meeting: original)
        let unresolved = analysis.1.result.intervals.filter { $0.clusterID == nil }.reduce(0) { $0 + $1.end - $1.start }
        let protected = original.transcript.filter { row in
            original.speakers.contains { $0.id == row.speakerID && $0.manuallyAssigned == true }
        }.count
        result.detail =
            "\(analysis.1.result.clusters.count) voice groups. \(Int(unresolved.rounded())) seconds of speaker activity need review. \(protected) manually assigned passages kept."
        guard !result.ranges.isEmpty else {
            throw ServiceError(
                "Voice samples did not resolve speaker ranges. Use Label Speakers to analyze the saved audio.")
        }
        await voiceLibrary.awaitLoaded()
        let current = try await validatedMeetingForSpeakerLabeling(
            resultID: result.id, original: original, files: files, sourceRevisions: revisions)
        try SpeakerEvidenceInputReceipt.validate(directory: folder, files: files, expected: analysis.2)
        try Task.checkCancellation()
        var updated = MeetingSpeakerConsolidation.applying(result, to: current)
        updated.speakerLabelSource = .init(
            resultID: result.id, providerName: "Speaker Consolidation", generatedAt: result.generatedAt)
        // Project existing human decisions before staging any unreviewed examples.
        updated = voiceLibrary.applyingDecisions(to: updated)
        markManagedTaskCompletion(on: &updated, kind: .diarization)
        let byID = Dictionary(analysis.0.samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var examples: [VoiceExample] = []
        for cluster in analysis.1.result.clusters {
            let speakerID = MeetingSpeakerConsolidation.speakerIdentity(
                cluster: cluster, result: analysis.1.result, evidence: analysis.0, meeting: original)
            guard updated.speakers.contains(where: { $0.id == speakerID }) else { continue }
            for sampleID in cluster.representativeSampleIDs {
                guard let sample = byID[sampleID],
                    let file = updated.audioFiles.first(where: {
                        LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == sample.source
                    }), let revision = revisions[folder.appendingPathComponent(file)]
                else { continue }
                examples.append(
                    VoiceExample(
                        id: MeetingSpeakerConsolidation.identity(
                            meetingID: id, clusterID: cluster.id + ":" + sample.id),
                        meetingID: id, speakerID: speakerID, source: sample.source,
                        audioFile: file, audioRevision: revision, start: sample.start, end: sample.end,
                        review: .unassigned, embeddings: [sample.embedding], groupID: speakerID, origin: .savedSpeaker))
            }
        }
        func artifact(_ name: String, _ data: Data) throws -> CanonicalMeetingArtifact {
            try PrivateTranscriptFile.validatePath(name: name, at: folder)
            let url = folder.appendingPathComponent(name)
            let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            return .init(meetingID: id, name: name, data: data, previous: previous)
        }
        var artifacts = [
            try artifact("speaker-labels-\(result.id).json", JSONEncoder().encode(result)),
            try artifact(
                "speaker-consolidation-\(result.id).json",
                JSONEncoder().encode(
                    ConsolidationReceipt(input: analysis.2, configuration: .init(), analysis: analysis.1))),
        ]
        // Derive history from the same bytes used as the transaction baseline.
        var history = try artifact("transcript-revisions.json", Data())
        if let bytes = try TranscriptRevisions.preserving(current, previous: history.previous) {
            history.data = bytes
            artifacts.append(history)
        }
        let committed = await commitSpeakerConsolidation(
            expected: current, updated: updated, examples: examples, artifacts: artifacts,
            validateInputs: {
                _ = try SpeakerEvidenceInputReceipt.validate(directory: folder, files: files, expected: analysis.2)
            })
        guard committed else { throw ServiceError(errorMessage ?? "Couldn’t save consolidated speaker labels.") }
        if settings.recognizeSpeakers { voiceLibrary.suggestReviewedPeople(from: people) }
    }
}

private struct ConsolidationReceipt: Codable {
    var version = 2
    var input: SpeakerEvidenceInputReceipt
    var configuration: SpeakerConsolidation.Configuration
    var analysis: SpeakerConsolidation.Analysis
}
