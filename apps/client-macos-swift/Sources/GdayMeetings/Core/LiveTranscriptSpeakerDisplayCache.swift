import Foundation

/// Stable finalized attribution keeps its displayed speaker mapping between partial updates.
@MainActor
final class LiveTranscriptSpeakerDisplayCache {
    private var meetingID: UUID?
    private var input: [LiveTranscriptPhrase] = []
    private var output: [LiveTranscriptPhrase] = []
    private var enabled = false
    private var people: Set<UUID> = []
    private(set) var mappedCount = 0

    func rows(
        _ phrases: [LiveTranscriptPhrase], meetingID: UUID?, enabled: Bool, people: Set<UUID>
    ) -> [LiveTranscriptPhrase] {
        mappedCount = 0
        let sameConfiguration = self.meetingID == meetingID && self.enabled == enabled && self.people == people
        if sameConfiguration && input == phrases { return output }
        let appends =
            sameConfiguration && phrases.count >= input.count
            && phrases.prefix(input.count).elementsEqual(input)
        if !appends {
            input = []
            output = []
        }
        let added = phrases.dropFirst(input.count)
        output.append(contentsOf: added.map { $0.displayingSpeakerLabels(enabled, knownPeople: people) })
        mappedCount = added.count
        input = phrases
        self.meetingID = meetingID
        self.enabled = enabled
        self.people = people
        return output
    }
}
