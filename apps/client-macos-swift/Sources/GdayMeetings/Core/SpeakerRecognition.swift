import Foundation

/// Labels are scoped to one result and track. Names never replace provider IDs.
struct MeetingSpeaker: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var track: String
    var providerName: String
    /// RunPod does not report an embedding model version. Never compare across
    /// configured endpoints, or assume an imported Rust vector uses that model.
    var voiceScope: String?
    var embedding: [Double]?
    var personID: UUID?
    var confidence: Double?
    var confirmed = false
}

struct PersonVoiceSample: Codable, Equatable {
    var meetingID: UUID
    var speakerID: UUID
    var scope: String
    var embedding: [Double]
}

enum SpeakerRecognition {
    static let threshold = 0.75

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

    static func suggest(_ speakers: inout [MeetingSpeaker], people: [Person]) {
        var scores: [(speaker: Int, person: UUID, score: Double)] = []
        for (index, speaker) in speakers.enumerated() {
            guard let scope = speaker.voiceScope, let embedding = speaker.embedding else { continue }
            for person in people {
                let samples = person.voiceSamples.filter {
                    $0.scope == scope && $0.embedding.count == embedding.count && isValid($0.embedding)
                }
                guard !samples.isEmpty else { continue }
                var centroid = Array(repeating: 0.0, count: embedding.count)
                for sample in samples {
                    for dimension in centroid.indices {
                        centroid[dimension] += sample.embedding[dimension] / Double(samples.count)
                    }
                }
                if let score = similarity(embedding, centroid), score >= threshold {
                    scores.append((index, person.id, score))
                }
            }
        }
        scores.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.speaker != $1.speaker { return $0.speaker < $1.speaker }
            return $0.person.uuidString < $1.person.uuidString
        }
        var claimed: [String: Set<UUID>] = [:]
        var assigned = Set<Int>()
        for match in scores {
            let track = speakers[match.speaker].track
            guard !assigned.contains(match.speaker), !(claimed[track]?.contains(match.person) ?? false) else {
                continue
            }
            speakers[match.speaker].personID = match.person
            speakers[match.speaker].confidence = match.score
            speakers[match.speaker].confirmed = false
            assigned.insert(match.speaker)
            claimed[track, default: []].insert(match.person)
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
                        embedding: attempt.diarize ? segment.embedding : nil)
                    speakers.append(speaker)
                    speakerID = speaker.id
                }
            }
            let source = attempt.inputs.first { $0.trackName == segment.track }?.sourceType
            return TranscriptSegment(
                start: segment.start, end: segment.end,
                speaker: segment.speaker ?? (source == "mic" ? "You" : "Speaker"),
                text: segment.text, speakerID: speakerID)
        }
        suggest(&speakers, people: people)
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

    func speakerName(for segment: TranscriptSegment, people: [Person]) -> String {
        guard let speaker = speakers.first(where: { $0.id == segment.speakerID }),
            let person = people.first(where: { $0.id == speaker.personID })
        else { return segment.speaker }
        return speaker.confirmed ? person.name : "\(person.name) (Suggested)"
    }

    mutating func replaceSpeakers(_ replacement: [MeetingSpeaker]) {
        let previous = Set(speakers.filter(\.confirmed).compactMap(\.personID))
        personIDs.removeAll { previous.contains($0) }
        speakers = replacement
        for speaker in replacement where speaker.confirmed {
            if let id = speaker.personID, !personIDs.contains(id) { personIDs.append(id) }
        }
    }
}

extension MeetingStore {
    /// Save the assignment and confirmed sample together through the library's
    /// atomic save/rollback path. Reassignment removes its earlier training sample.
    func assignSpeaker(meetingID: UUID, speakerID: UUID, personID: UUID?) {
        guard libraryWritable, var meeting = meetings.first(where: { $0.id == meetingID }),
            let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }),
            personID == nil || people.contains(where: { $0.id == personID })
        else { return }
        var replacement = meeting.speakers
        replacement[index].personID = personID
        replacement[index].confidence = nil
        replacement[index].confirmed = personID != nil
        for i in people.indices {
            people[i].voiceSamples.removeAll { $0.meetingID == meetingID && $0.speakerID == speakerID }
        }
        if let personIndex = people.firstIndex(where: { $0.id == personID }),
            let scope = replacement[index].voiceScope, let embedding = replacement[index].embedding,
            SpeakerRecognition.isValid(embedding)
        {
            people[personIndex].voiceSamples.append(
                PersonVoiceSample(meetingID: meetingID, speakerID: speakerID, scope: scope, embedding: embedding))
        }
        meeting.replaceSpeakers(replacement)
        updateMeeting(meeting)
    }
}
