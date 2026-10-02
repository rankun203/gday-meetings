import Foundation

/// Append-only completed paragraphs and a replaceable, bounded live tail.
/// Consumers keep their own cursor instead of comparing historical arrays.
final class LiveTranscriptStreamDisplayCache {
    private var frozen: [TranscriptDisplayRow] = []
    private var frozenPhrases: [UUID: LiveTranscriptPhrase] = [:]
    private var hot: [TranscriptDisplayRow] = []
    private var hotPhrases: [UUID: LiveTranscriptPhrase] = [:]
    private var pending: [LiveTranscriptPhrase] = []
    private var consumed = 0
    private var sourceReset: Int?
    private var sourceRevision: Int?
    private var names: [UUID: String] = [:]
    private var enabled = true
    private var recognitionEnabled = true
    private var unresolvedFrozen = false
    private(set) var resetRevision = 0
    private(set) var revision = 0
    private(set) var rebuiltParagraphCount = 0
    var frozenCount: Int { frozen.count }
    var count: Int { frozen.count + hot.count }
    var hasUnresolvedTiming: Bool { unresolvedFrozen || hotPhrases.values.contains(where: \.hasUnresolvedTiming) }

    func row(at index: Int) -> TranscriptDisplayRow {
        index < frozen.count ? frozen[index] : hot[index - frozen.count]
    }
    func phrase(id: UUID) -> LiveTranscriptPhrase? { hotPhrases[id] ?? frozenPhrases[id] }
    func rows(from index: Int) -> [TranscriptDisplayRow] { (index..<count).map { row(at: $0) } }

    func update(_ stream: LiveTranscriptStream, people: [Person], enabled: Bool, recognitionEnabled: Bool) {
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let reset = sourceReset != stream.resetRevision || self.names != names || self.enabled != enabled
        guard reset || sourceRevision != stream.revision || self.recognitionEnabled != recognitionEnabled else {
            return
        }
        if reset {
            frozen.removeAll(keepingCapacity: true)
            frozenPhrases.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            consumed = 0
            unresolvedFrozen = false
            resetRevision += 1
        }
        self.names = names
        self.enabled = enabled
        self.recognitionEnabled = recognitionEnabled
        sourceReset = stream.resetRevision
        sourceRevision = stream.revision
        let peopleIDs = Set(names.keys)
        func display(_ phrase: LiveTranscriptPhrase) -> LiveTranscriptPhrase {
            phrase.displayingSpeakerLabels(enabled, knownPeople: peopleIDs)
        }
        // Retain only the last completed paragraph: the next phrase may join it.
        for index in consumed..<stream.frozenCount { pending.append(display(stream.frozenRow(at: index))) }
        consumed = stream.frozenCount
        let completed = LiveTranscriptParagraphs.groups(finalized: pending, partials: [])
        if completed.count > 1 {
            let sealed = Array(completed.dropLast())
            let snapshot = LiveTranscriptDisplay.snapshot(groups: sealed, names: names, activePhraseID: nil)
            frozen.append(contentsOf: snapshot.rows)
            frozenPhrases.merge(snapshot.phrases, uniquingKeysWith: { _, value in value })
            unresolvedFrozen = unresolvedFrozen || sealed.contains { $0.phrase.hasUnresolvedTiming }
        }
        pending = completed.last?.parts.map(\.phrase) ?? []
        let partials = stream.hotPartials.map(display)
        let groups = LiveTranscriptParagraphs.groups(
            finalized: pending + stream.hotFinalized.map(display), partials: partials)
        let snapshot = LiveTranscriptDisplay.snapshot(
            groups: groups, names: names,
            activePhraseID: recognitionEnabled ? LiveTranscriptPresentation.activePhraseID(partials) : nil)
        hot = snapshot.rows
        hotPhrases = snapshot.phrases
        rebuiltParagraphCount = completed.count + groups.count
        revision += 1
    }
}
