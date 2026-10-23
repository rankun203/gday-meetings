import Foundation

/// Labels are scoped to one result and track. Names never replace provider IDs.
struct MeetingSpeaker: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var label: String
    var track: String
    var providerName: String
    /// Legacy provenance only. An endpoint does not establish model compatibility.
    var voiceScope: String?
    var embedding: [Double]?
    var voiceEmbedding: TypedVoiceEmbedding?
    var personID: UUID?
    var confidence: Double?
    /// Legacy library key retained for older clients. Assignment is determined by personID.
    var confirmed = false
    /// Present only when this entry represents an audio source, not a detected voice.
    var sourcePlaceholder: LiveAudioSource?
    var voiceSampleRange: VoiceSampleRange?
    var voiceSampleRevision: String?
    /// Optional for older libraries; nil does not prove human review.
    var manuallyAssigned: Bool?
    /// Live reviews cover observed speech; nil retains whole-label review semantics.
    var manualReviewThrough: [String: Double]?
    var voiceReviewOrigin: VoiceProjectionOrigin?
    var voiceReviewExampleID: UUID?
    /// A meeting-local palette slot, independent of the assigned person's name.
    var colorSlot: Int?
    var passageAssignmentOrigin: TranscriptPassageOrigin?

    func protectsManualAssignment(to row: TranscriptSegment) -> Bool {
        guard manuallyAssigned == true else { return false }
        guard let watermarks = manualReviewThrough else { return true }
        let source = row.source?.rawValue ?? (["mic": "microphone", "system_mix": "system"][track] ?? track)
        guard source == "microphone" || source == "system" else { return true }
        // Preserve a complete row if any of it was explicitly reviewed.
        return row.start < (watermarks[source] ?? 0)
    }

    /// Tentative transcript names do not establish meeting attendance.
    var attendancePersonID: UUID? {
        voiceReviewOrigin?.transcriptAssociationTier == .tentative ? nil : personID
    }

    var canAssignPerson: Bool { sourcePlaceholder == nil }
    var canReviewVoice: Bool { canAssignPerson && resolvedVoiceEmbedding?.isValid == true }
    var displayLabel: String {
        label.isEmpty ? "" : sourcePlaceholder?.shortLabel ?? SpeakerLabelPresentation.display(label)
    }

    var resolvedVoiceEmbedding: TypedVoiceEmbedding? {
        voiceEmbedding
            ?? embedding.map {
                .init(type: .unknownLegacy(dimension: $0.count), values: $0, provenance: voiceScope)
            }
    }
}

struct PersonVoiceSample: Codable, Equatable, Sendable {
    var meetingID: UUID
    var speakerID: UUID
    var scope: String
    var embedding: [Double]
    var voiceEmbedding: TypedVoiceEmbedding?

    init(meetingID: UUID, speakerID: UUID, scope: String, embedding: [Double]) {
        self.meetingID = meetingID
        self.speakerID = speakerID
        self.scope = scope
        self.embedding = embedding
    }

    init(meetingID: UUID, speakerID: UUID, voiceEmbedding: TypedVoiceEmbedding) {
        self.meetingID = meetingID
        self.speakerID = speakerID
        self.scope = voiceEmbedding.provenance ?? voiceEmbedding.type.modelID
        self.embedding = voiceEmbedding.values
        self.voiceEmbedding = voiceEmbedding
    }

    var resolvedVoiceEmbedding: TypedVoiceEmbedding {
        voiceEmbedding ?? .init(type: .unknownLegacy(dimension: embedding.count), values: embedding, provenance: scope)
    }
}

enum SpeakerRecognition {
    // Conservative initial policy; not a calibrated probability of identity.
    static let threshold = VoiceMatchingPolicy.default.automaticThreshold

    static func match(
        embedding: TypedVoiceEmbedding, people: [Person],
        threshold: Double = VoiceMatchingPolicy.default.automaticThreshold,
        minimumMargin: Double = VoiceMatchingPolicy.default.minimumMargin
    ) -> VoiceMatch? {
        guard embedding.isValid, threshold.isFinite, minimumMargin.isFinite,
            (-1...1).contains(threshold), minimumMargin >= 0
        else { return nil }
        let scores: [(UUID, Double)] = people.compactMap { person in
            let candidates = person.voiceSamples.compactMap { sample -> SpeakerEvidenceSample? in
                let value = sample.resolvedVoiceEmbedding
                guard value.type == embedding.type, value.isValid else { return nil }
                return .init(
                    id: sample.meetingID.uuidString + ":" + sample.speakerID.uuidString,
                    source: "reviewed", localSpeakerID: sample.speakerID.uuidString,
                    start: 0, end: 0, embedding: value)
            }
            let samples = candidates.count > 12 ? VoiceProfileSelection.select(candidates, limit: 12) : candidates
            guard let score = samples.compactMap({ similarity(embedding.values, $0.vector) }).max() else { return nil }
            return (person.id, score)
        }.sorted { $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 > $1.1 }
        guard let best = scores.first else { return nil }
        let margin = best.1 - (scores.dropFirst().first?.1 ?? -1)
        guard best.1 >= threshold, margin >= minimumMargin else { return nil }
        return .init(personID: best.0, score: best.1, margin: margin)
    }

    static func isValid(_ vector: [Double]) -> Bool {
        !vector.isEmpty && vector.count <= 4096 && vector.allSatisfy(\.isFinite)
            && vector.contains { $0 != 0 }
    }

    static func similarity(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, isValid(lhs), isValid(rhs) else { return nil }
        // Scaling first avoids overflow for malformed, very large finite values.
        let leftScale = lhs.map(abs).max()!
        let rightScale = rhs.map(abs).max()!
        let a = lhs.map { $0 / leftScale }
        let b = rhs.map { $0 / rightScale }
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        return max(-1, min(1, dot / sqrt(a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 })))
    }

    static func match(_ speakers: inout [MeetingSpeaker], people: [Person]) {
        var scores: [(speaker: Int, person: UUID, score: Double)] = []
        for (index, speaker) in speakers.enumerated() {
            guard speaker.manuallyAssigned != true else { continue }
            guard let embedding = speaker.resolvedVoiceEmbedding else { continue }
            if let match = match(embedding: embedding, people: people) {
                scores.append((index, match.personID, match.score))
            }
        }
        scores.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.speaker != $1.speaker { return $0.speaker < $1.speaker }
            return $0.person.uuidString < $1.person.uuidString
        }
        var assigned = Set<Int>()
        for match in scores {
            guard !assigned.contains(match.speaker) else {
                continue
            }
            speakers[match.speaker].personID = match.person
            speakers[match.speaker].confidence = match.score
            speakers[match.speaker].confirmed = true
            assigned.insert(match.speaker)
        }
    }

    static func result(
        _ segments: [ServerTranscriptSegment], attempt: ProviderTranscriptionAttempt, people: [Person]
    ) -> (segments: [TranscriptSegment], speakers: [MeetingSpeaker]) {
        var speakers: [MeetingSpeaker] = []
        let result = segments.map { segment in
            var speakerID: UUID?
            if let label = segment.speaker, !label.isEmpty {
                if let existing = speakers.first(where: { $0.track == segment.track && $0.label == label }) {
                    speakerID = existing.id
                }
                else {
                    let speaker = MeetingSpeaker(
                        label: label, track: segment.track, providerName: attempt.kind.title,
                        voiceScope: attempt.kind == .runpod ? "runpod:" + attempt.endpoint : nil,
                        embedding: attempt.diarize ? segment.embedding : nil,
                        voiceEmbedding: attempt.diarize ? segment.voiceEmbedding : nil)
                    speakers.append(speaker)
                    speakerID = speaker.id
                }
            }
            var result = TranscriptSegment(
                start: segment.start, end: segment.end,
                speaker: segment.speaker ?? "",
                text: segment.text, speakerID: speakerID)
            result.timing = segment.timing
            result.analysisTrackID =
                attempt.inputs.firstIndex { $0.trackName == segment.track }
                .map { "track\($0)" } ?? segment.track
            let source = attempt.inputs.first { $0.trackName == segment.track }?.sourceType ?? segment.track
            switch source.lowercased() {
            case "mic", "microphone": result.source = .microphone
            case "sys", "system", "system_mix": result.source = .system
            default: break
            }
            return result
        }
        // Provider labels are retained without turning a similarity guess into
        // a person's name. Playable evidence is reviewed in the voice library.
        return (result, speakers)
    }
}

extension Meeting {
    /// People includes every attributed passage while retaining independent attendees.
    var associatedPersonIDs: [UUID] {
        let byID = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let attributed = transcript.compactMap { row -> UUID? in
            guard let id = row.speakerID, let speaker = byID[id], row.allowsPersonAssociation(from: speaker)
            else { return nil }
            return speaker.personID
        }
        return Array(Set(personIDs + speakers.compactMap(\.attendancePersonID) + attributed)).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    /// Old Swift transcripts stored display names only. Preserve them as labels,
    /// without guessing a Person link or creating a voice recognition sample.
    mutating func restoreSpeakerIdentities() {
        for index in transcript.indices where !speakers.contains(where: { $0.id == transcript[index].speakerID }) {
            let label = transcript[index].speaker
            guard !label.isEmpty else { continue }
            let speaker =
                speakers.first { $0.label == label && $0.track.isEmpty }
                ?? MeetingSpeaker(label: label, track: "", providerName: "Imported Transcript")
            if !speakers.contains(where: { $0.id == speaker.id }) { speakers.append(speaker) }
            transcript[index].speakerID = speaker.id
        }
    }

    func speakerName(
        for segment: TranscriptSegment, people: [Person],
        compactProviderLabel: Bool = false,
        tentativeNameSuffix: String = " (Tentative)"
    ) -> String {
        if let speaker = speakers.first(where: { $0.id == segment.speakerID }) {
            if segment.allowsPersonAssociation(from: speaker),
                let person = people.first(where: { $0.id == speaker.personID })
            {
                return speaker.voiceReviewOrigin?.transcriptAssociationTier == .tentative
                    ? person.name + tentativeNameSuffix : person.name
            }
            if speaker.sourcePlaceholder != nil { return speaker.displayLabel }
        }
        return compactProviderLabel ? SpeakerLabelPresentation.display(segment.speaker) : segment.speaker
    }

    mutating func replaceSpeakers(_ replacement: [MeetingSpeaker]) {
        let previous = Set(speakers.compactMap(\.attendancePersonID))
        personIDs.removeAll { previous.contains($0) }
        speakers = replacement
        for index in speakers.indices {
            speakers[index].confirmed = speakers[index].attendancePersonID != nil
        }
        for speaker in speakers {
            if let id = speaker.attendancePersonID, !personIDs.contains(id) { personIDs.append(id) }
        }
    }
}

extension MeetingStore {
    /// Save transcript identity through the library's atomic save/rollback path.
    /// Correcting a derived name preserves independent reference reviews.
    @discardableResult func assignSpeaker(meetingID: UUID, speakerID: UUID, personID: UUID?) async -> Bool {
        guard await voiceLibrary.awaitReady() else {
            errorMessage = voiceLibrary.errorMessage
            return false
        }
        guard await ensureMeetingLoaded(id: meetingID) else { return false }
        guard await flushCanonicalWrites() else { return false }
        guard libraryWritable, var meeting = self.meeting(id: meetingID),
            let selected = meeting.speakers.first(where: { $0.id == speakerID })
        else { return false }
        // Existing passage corrections retain their independent identity and
        // Undo scope. New whole-speaker choices only unwrap machine projections.
        let originID = selected.passageAssignmentOrigin == nil ? selected.voiceReviewOrigin?.speakerID : nil
        let canonicalID =
            originID.flatMap { origin in
                meeting.speakers.contains(where: { $0.id == origin }) ? origin : nil
            } ?? speakerID
        guard let index = meeting.speakers.firstIndex(where: { $0.id == canonicalID }),
            meeting.speakers[index].canAssignPerson || personID == nil,
            personID == nil || people.contains(where: { $0.id == personID })
        else { return false }
        var replacement = meeting.speakers
        let speaker = meeting.speakers[index]
        replacement[index].voiceReviewOrigin?.transcriptAssociationTier = nil
        replacement[index].personID = personID
        replacement[index].confidence = nil
        replacement[index].confirmed = personID != nil
        replacement[index].manuallyAssigned = true
        replacement[index].manualReviewThrough = nil
        _ = voiceLibrary.ingest(meeting: meeting, directory: directory(for: meetingID))
        guard
            voiceLibrary.assign(
                meetingID: meetingID, speakerID: canonicalID, personID: personID, staged: true,
                previousPersonID: meeting.speakers[index].personID,
                preservePreviousSpeakerDecision: speaker.voiceReviewOrigin?.speakerID != canonicalID,
                updateReferenceEvidence: false,
                relatedExampleID: speaker.voiceReviewExampleID)
        else {
            errorMessage = voiceLibrary.errorMessage
            return false
        }
        // Legacy profile vectors carry no excerpt-quality decision. New evidence
        // is selected from supported audio after the transcript identity is saved.
        let legacySpeakerIDs = Set(
            meeting.speakers.filter {
                $0.id == canonicalID
                    || ($0.passageAssignmentOrigin == nil && $0.voiceReviewOrigin?.speakerID == canonicalID)
            }.map(\.id))
        for i in people.indices {
            people[i].voiceSamples.removeAll { $0.meetingID == meetingID && legacySpeakerIDs.contains($0.speakerID) }
        }
        for index in replacement.indices
        where replacement[index].passageAssignmentOrigin?.speakerID == canonicalID
            || replacement[index].voiceReviewOrigin?.speakerID == canonicalID
        {
            replacement[index].passageAssignmentOrigin?.labelDecisionChanged = true
            // Preserve independently corrected passages when the base speaker is
            // renamed. A passage explicitly selected for this action follows it.
            if replacement[index].passageAssignmentOrigin != nil && replacement[index].id != speakerID { continue }
            replacement[index].voiceReviewOrigin?.transcriptAssociationTier = nil
            replacement[index].personID = personID
            replacement[index].manuallyAssigned = true
        }
        meeting.replaceSpeakers(replacement)
        guard await updateMeeting(meeting) else { return false }
        voicePreparation.cancelReference(speakerID: canonicalID)
        if let personID {
            voicePreparation.selectReference(
                meetingID: meetingID, speakerID: canonicalID, personID: personID,
                exampleID: speaker.voiceReviewExampleID, directory: directory(for: meetingID))
        }
        return true
    }
}

/// Presentation only: canonical provider labels remain unchanged in the library.
enum SpeakerLabelPresentation {
    static func display(_ label: String) -> String {
        for source in ["mic", "sys"] {
            let prefix = source + "_SPEAKER_"
            guard label.hasPrefix(prefix) else { continue }
            let number = label.dropFirst(prefix.count)
            guard !number.isEmpty, number.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return label }
            return source + "_" + number
        }
        return label
    }
}

extension TranscriptSegment {
    func allowsPersonAssociation(from speaker: MeetingSpeaker?) -> Bool {
        guard associationUncertain == true else { return true }
        guard let speaker, speaker.manuallyAssigned == true else { return false }
        guard let through = speaker.manualReviewThrough else { return true }
        guard let source, let end = through[source.rawValue] else { return false }
        return self.end <= end
    }
}
