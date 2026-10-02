import Foundation

/// Keeps assembled paragraphs and native row models before the changed tail.
/// A historical revision rebuilds from its paragraph boundary; ordinary partial
/// updates touch only the final paragraphs that can join the new text.
final class LiveTranscriptDisplayCache {
    private var meetingID: UUID?
    private var finalized: [LiveTranscriptPhrase] = []
    private var partials: [LiveTranscriptPhrase] = []
    private var overrides: [LiveTranscriptOverride] = []
    private var names: [UUID: String] = [:]
    private var recognitionEnabled = true
    private var groups: [LiveTranscriptParagraphs.Paragraph] = []
    private var rows: [TranscriptDisplayRow] = []
    private var phrases: [UUID: LiveTranscriptPhrase] = [:]
    private(set) var rebuiltParagraphCount = 0

    func snapshot(
        meetingID: UUID?, finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase], people: [Person],
        recognitionEnabled: Bool = true, overrides: [LiveTranscriptOverride] = []
    ) -> (rows: [TranscriptDisplayRow], phrases: [UUID: LiveTranscriptPhrase]) {
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let reset = self.meetingID != meetingID || self.names != names || self.overrides != overrides
        var firstChange: Double?
        if !reset {
            let common = min(self.finalized.count, finalized.count)
            var index = self.finalized == finalized ? common : 0
            while index < common, self.finalized[index] == finalized[index] { index += 1 }
            if index < self.finalized.count { firstChange = self.finalized[index].start }
            if index < finalized.count { firstChange = min(firstChange ?? .infinity, finalized[index].start) }
            if self.partials != partials || self.recognitionEnabled != recognitionEnabled {
                for phrase in self.partials + partials {
                    firstChange = min(firstChange ?? .infinity, phrase.start)
                }
            }
        }
        self.meetingID = meetingID
        self.finalized = finalized
        self.partials = partials
        self.names = names
        self.overrides = overrides
        self.recognitionEnabled = recognitionEnabled
        rebuiltParagraphCount = 0
        guard reset || firstChange != nil else { return (rows, phrases) }

        var rebuildFrom = 0
        if !reset, let firstChange {
            // Include the previous paragraph because a revised first phrase can
            // now join it. Overlapping source paragraphs can start earlier.
            let affected = groups.firstIndex { $0.phrase.end >= firstChange } ?? groups.count
            rebuildFrom = max(0, affected - 1)
        }
        // The ordering policy intentionally has ties. Never retain only one
        // member of a tied boundary and then discard the others in tail().
        while rebuildFrom > 0, rebuildFrom < groups.count,
            let left = groups[rebuildFrom - 1].parts.last?.phrase,
            let right = groups[rebuildFrom].parts.first?.phrase,
            !LiveTranscriptPhrase.ordered(left, right), !LiveTranscriptPhrase.ordered(right, left)
        {
            rebuildFrom -= 1
        }
        let boundary = rebuildFrom > 0 ? groups[rebuildFrom - 1].parts.last?.phrase : nil
        func tail(_ values: [LiveTranscriptPhrase]) -> [LiveTranscriptPhrase] {
            guard let boundary else { return values }
            var lower = 0
            var upper = values.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if LiveTranscriptPhrase.ordered(boundary, values[middle]) {
                    upper = middle
                }
                else {
                    lower = middle + 1
                }
            }
            return Array(values[lower...])
        }
        let replacement = LiveTranscriptParagraphs.groups(
            finalized: tail(finalized), partials: tail(partials.sorted(by: LiveTranscriptPhrase.ordered)),
            overrides: overrides)
        let replacementSnapshot = LiveTranscriptDisplay.snapshot(
            groups: replacement, names: names,
            activePhraseID: recognitionEnabled ? LiveTranscriptPresentation.activePhraseID(partials) : nil)
        for row in rows[rebuildFrom...] { phrases.removeValue(forKey: row.id) }
        groups.replaceSubrange(rebuildFrom..., with: replacement)
        rows.replaceSubrange(rebuildFrom..., with: replacementSnapshot.rows)
        phrases.merge(replacementSnapshot.phrases, uniquingKeysWith: { _, latest in latest })
        rebuiltParagraphCount = replacement.count
        return (rows, phrases)
    }
}
