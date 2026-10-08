import Foundation

/// Fragment embeddings must not look like a contiguous playable example to older clients.
/// Keeping the coding implementation in an extension preserves the memberwise initializer.
extension MeetingSpeaker {
    private enum CodingKeys: String, CodingKey {
        case id, label, track, providerName, voiceScope, embedding, voiceEmbedding, personID, confidence, confirmed,
            sourcePlaceholder, voiceSampleRange, voiceSampleRevision, manuallyAssigned, manualReviewThrough,
            voiceReviewOrigin, voiceReviewExampleID, colorSlot, passageAssignmentOrigin
        case fragmentVoiceEmbedding, fragmentLegacyEmbedding
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try values.decode(String.self, forKey: .label),
            track: try values.decode(String.self, forKey: .track),
            providerName: try values.decode(String.self, forKey: .providerName))
        id = try values.decode(UUID.self, forKey: .id)
        voiceScope = try values.decodeIfPresent(String.self, forKey: .voiceScope)
        personID = try values.decodeIfPresent(UUID.self, forKey: .personID)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        confirmed = try values.decode(Bool.self, forKey: .confirmed)
        sourcePlaceholder = try values.decodeIfPresent(LiveAudioSource.self, forKey: .sourcePlaceholder)
        voiceSampleRange = try values.decodeIfPresent(VoiceSampleRange.self, forKey: .voiceSampleRange)
        voiceSampleRevision = try values.decodeIfPresent(String.self, forKey: .voiceSampleRevision)
        manuallyAssigned = try values.decodeIfPresent(Bool.self, forKey: .manuallyAssigned)
        manualReviewThrough = try values.decodeIfPresent([String: Double].self, forKey: .manualReviewThrough)
        voiceReviewOrigin = try values.decodeIfPresent(VoiceProjectionOrigin.self, forKey: .voiceReviewOrigin)
        voiceReviewExampleID = try values.decodeIfPresent(UUID.self, forKey: .voiceReviewExampleID)
        colorSlot = try values.decodeIfPresent(Int.self, forKey: .colorSlot)
        passageAssignmentOrigin = try values.decodeIfPresent(
            TranscriptPassageOrigin.self, forKey: .passageAssignmentOrigin)
        let fragmented = try values.decodeIfPresent(TypedVoiceEmbedding.self, forKey: .fragmentVoiceEmbedding)
        let rawFragmented = try values.decodeIfPresent([Double].self, forKey: .fragmentLegacyEmbedding)
        let ordinary = try values.decodeIfPresent(TypedVoiceEmbedding.self, forKey: .voiceEmbedding)
        let rawOrdinary = try values.decodeIfPresent([Double].self, forKey: .embedding)
        guard (fragmented == nil && rawFragmented == nil) || (ordinary == nil && rawOrdinary == nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .fragmentVoiceEmbedding, in: values,
                debugDescription: "Conflicting legacy and fragmented voice evidence")
        }
        voiceEmbedding = fragmented ?? ordinary
        embedding = rawFragmented ?? rawOrdinary
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(label, forKey: .label)
        try values.encode(track, forKey: .track)
        try values.encode(providerName, forKey: .providerName)
        try values.encodeIfPresent(voiceScope, forKey: .voiceScope)
        try values.encodeIfPresent(personID, forKey: .personID)
        try values.encodeIfPresent(confidence, forKey: .confidence)
        try values.encode(confirmed, forKey: .confirmed)
        try values.encodeIfPresent(sourcePlaceholder, forKey: .sourcePlaceholder)
        try values.encodeIfPresent(voiceSampleRange, forKey: .voiceSampleRange)
        try values.encodeIfPresent(voiceSampleRevision, forKey: .voiceSampleRevision)
        try values.encodeIfPresent(manuallyAssigned, forKey: .manuallyAssigned)
        try values.encodeIfPresent(manualReviewThrough, forKey: .manualReviewThrough)
        try values.encodeIfPresent(voiceReviewOrigin, forKey: .voiceReviewOrigin)
        try values.encodeIfPresent(voiceReviewExampleID, forKey: .voiceReviewExampleID)
        try values.encodeIfPresent(colorSlot, forKey: .colorSlot)
        try values.encodeIfPresent(passageAssignmentOrigin, forKey: .passageAssignmentOrigin)
        let provenance = voiceEmbedding?.provenance ?? voiceScope ?? ""
        let fragmented =
            voiceSampleRange?.spans != nil
            || provenance.hasPrefix("clean-fragments-")
            || provenance == "saved-example-clean-fragments-v1"
        try values.encodeIfPresent(voiceEmbedding, forKey: fragmented ? .fragmentVoiceEmbedding : .voiceEmbedding)
        try values.encodeIfPresent(embedding, forKey: fragmented ? .fragmentLegacyEmbedding : .embedding)
    }
}
