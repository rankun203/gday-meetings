import Foundation

/// Identity metadata may mature after words are sealed. Aliases never change
/// transcript timing/text, and malformed cyclic metadata resolves to its input.
enum LiveSpeakerAliases {
    static func resolve(_ id: UUID, aliases: [UUID: UUID]) -> UUID {
        var current = id
        var visited = Set<UUID>()
        while let next = aliases[current] {
            guard visited.insert(current).inserted, next != current else { return id }
            current = next
        }
        return current
    }

    static func applying(
        _ phrase: LiveTranscriptPhrase, aliases: [UUID: UUID], speakers: [UUID: LiveSpeakerIdentity]
    ) -> LiveTranscriptPhrase {
        guard let original = phrase.speakerIdentity, speakers[original]?.manuallyAssigned != true else { return phrase }
        let id = resolve(original, aliases: aliases)
        guard id != original, let speaker = speakers[id] else { return phrase }
        var value = phrase
        value.speakerIdentity = id
        value.diarizationLabel = speaker.label
        value.speakerColorSlot = speaker.colorSlot
        value.voiceEmbedding = speaker.voiceEmbedding
        value.personID = speaker.personID
        return value
    }
}
