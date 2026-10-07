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
    var voiceReviewOrigin: VoiceProjectionOrigin?
    var voiceReviewExampleID: UUID?
    /// A meeting-local palette slot, independent of the assigned person's name.
    var colorSlot: Int?

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

struct PersonVoiceSample: Codable, Equatable {
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
    static let threshold = 0.85

    static func match(
        embedding: TypedVoiceEmbedding, people: [Person],
        threshold: Double = 0.85, minimumMargin: Double = 0.08
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
            return TranscriptSegment(
                start: segment.start, end: segment.end,
                speaker: segment.speaker ?? "",
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines), speakerID: speakerID)
        }
        // Provider labels are retained without turning a similarity guess into
        // a person's name. Playable evidence is reviewed in the voice library.
        return (result, speakers)
    }
}

extension Meeting {
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
        compactProviderLabel: Bool = false
    ) -> String {
        if let speaker = speakers.first(where: { $0.id == segment.speakerID }) {
            if let person = people.first(where: { $0.id == speaker.personID }) { return person.name }
            if speaker.sourcePlaceholder != nil { return speaker.displayLabel }
        }
        return compactProviderLabel ? SpeakerLabelPresentation.display(segment.speaker) : segment.speaker
    }

    mutating func replaceSpeakers(_ replacement: [MeetingSpeaker]) {
        let previous = Set(speakers.compactMap(\.personID))
        personIDs.removeAll { previous.contains($0) }
        speakers = replacement
        for index in speakers.indices { speakers[index].confirmed = speakers[index].personID != nil }
        for speaker in speakers {
            if let id = speaker.personID, !personIDs.contains(id) { personIDs.append(id) }
        }
    }
}

extension MeetingStore {
    /// Save the assignment and explicitly assigned sample together through the library's
    /// atomic save/rollback path. Reassignment removes its earlier training sample.
    func assignSpeaker(meetingID: UUID, speakerID: UUID, personID: UUID?) async {
        invalidatePendingLiveVoiceEnrollment(meetingID: meetingID, speakerID: speakerID)
        guard await voiceLibrary.awaitReady() else {
            errorMessage = voiceLibrary.errorMessage
            return
        }
        guard await ensureMeetingLoaded(id: meetingID) else { return }
        guard await flushCanonicalWrites() else { return }
        guard libraryWritable, var meeting = self.meeting(id: meetingID),
            let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }),
            meeting.speakers[index].canAssignPerson || personID == nil,
            personID == nil || people.contains(where: { $0.id == personID })
        else { return }
        var replacement = meeting.speakers
        replacement[index].personID = personID
        replacement[index].confidence = nil
        replacement[index].confirmed = personID != nil
        replacement[index].manuallyAssigned = true
        _ = voiceLibrary.ingest(meeting: meeting, directory: directory(for: meetingID))
        guard
            voiceLibrary.assign(
                meetingID: meetingID, speakerID: speakerID, personID: personID, staged: true,
                previousPersonID: meeting.speakers[index].personID,
                exampleID: meeting.speakers[index].voiceReviewExampleID)
        else {
            errorMessage = voiceLibrary.errorMessage
            return
        }
        for i in people.indices {
            people[i].voiceSamples.removeAll { $0.meetingID == meetingID && $0.speakerID == speakerID }
        }
        if let personIndex = people.firstIndex(where: { $0.id == personID }),
            let embedding = replacement[index].voiceEmbedding, embedding.isValid
        {
            people[personIndex].voiceSamples.append(
                .init(meetingID: meetingID, speakerID: speakerID, voiceEmbedding: embedding))
        }
        else if let personIndex = people.firstIndex(where: { $0.id == personID }),
            let scope = replacement[index].voiceScope, let embedding = replacement[index].embedding,
            SpeakerRecognition.isValid(embedding)
        {
            people[personIndex].voiceSamples.append(
                PersonVoiceSample(meetingID: meetingID, speakerID: speakerID, scope: scope, embedding: embedding))
        }
        meeting.replaceSpeakers(replacement)
        await updateMeeting(meeting)
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
