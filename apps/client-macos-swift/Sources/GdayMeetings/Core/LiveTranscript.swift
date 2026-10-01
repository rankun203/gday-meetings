import CryptoKit
import Foundation

/// The live draft is independent of the editable/batch transcript. Replacing one never deletes the other.
struct LiveTranscriptDraft: Codable, Equatable {
    var version = 1
    var meetingID: UUID
    var provider = "This Mac"
    var locale: String
    var phrases: [LiveTranscriptPhrase] = []
    var gaps: [LiveTranscriptGap] = []
    var complete = false
    /// Optional for checkpoints written before live editing was available.
    var overrides: [LiveTranscriptOverride]?
    var speakerTimeline: LiveSpeakerTimeline?
    var speakerLabelsComplete: Bool?

    private var finalizedParagraphs: [LiveTranscriptPhrase] {
        LiveTranscriptParagraphs.groups(
            finalized: resolvedRows().finalized.sorted(by: LiveTranscriptPhrase.ordered), partials: [],
            overrides: overrides ?? []
        ).map(\.phrase)
    }

    var segments: [TranscriptSegment] {
        finalizedParagraphs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            TranscriptSegment(
                id: $0.id, start: $0.start, end: $0.end, speaker: $0.speakerLabel, text: $0.text,
                speakerID: $0.speakerIdentity ?? $0.id)
        }
    }

    var speakers: [MeetingSpeaker] {
        var seen = Set<UUID>()
        return finalizedParagraphs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap {
                // A source badge is not a voice identity. Each editable row has its own
                // assignment, even when several rows have the same source badge.
                let identity = $0.speakerIdentity ?? $0.id
                guard seen.insert(identity).inserted else { return nil }
                return MeetingSpeaker(
                    id: identity, label: $0.speakerLabel, track: $0.source.rawValue,
                    providerName: provider, voiceEmbedding: $0.voiceEmbedding,
                    personID: $0.personID, confirmed: $0.personID != nil)
            }
    }

    mutating func accept(_ phrase: LiveTranscriptPhrase) {
        guard phrase.start.isFinite, phrase.end.isFinite, phrase.start >= 0, phrase.end >= phrase.start,
            !phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let phrase = phrase.preservingIdentity(from: phrases)
        // Raw recognition is retained separately from manually anchored changes.
        phrases.removeAll {
            $0.source == phrase.source && $0.session == phrase.session
                && ($0.start == phrase.start || ($0.start < phrase.end && $0.end > phrase.start))
        }
        phrases.append(phrase)
    }

    mutating func updateText(_ text: String, for phrase: LiveTranscriptPhrase) {
        changeOverride(for: phrase) { $0.text = text }
    }

    mutating func assignPerson(_ personID: UUID?, for phrase: LiveTranscriptPhrase, speakerIdentity: UUID? = nil) {
        changeOverride(for: phrase) {
            $0.personID = personID
            $0.personWasAssigned = true
            $0.scopedSpeakerIdentity = speakerIdentity
        }
    }

    private mutating func changeOverride(
        for phrase: LiveTranscriptPhrase, change: (inout LiveTranscriptOverride) -> Void
    ) {
        var values = overrides ?? []
        if let index = values.firstIndex(where: { $0.id == phrase.id }) {
            change(&values[index])
        }
        else {
            var value = LiveTranscriptOverride(anchor: phrase)
            change(&value)
            values.append(value)
        }
        overrides = values
    }

    /// Timed words partition recognition around fixed manual ranges. If word
    /// timing is missing, retain the complete recognition row beside the edit.
    /// Never guess which unaligned text lies outside a person's edited range.
    func resolvedRows(partials: [LiveTranscriptPhrase] = []) -> (
        finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase]
    ) {
        let changes = overrides ?? []
        var finalized: [LiveTranscriptPhrase] = []
        var pending: [LiveTranscriptPhrase] = []
        var preceding: [LiveAudioSource: LiveTranscriptPhrase] = [:]
        func attribute(_ values: [LiveTranscriptPhrase]) -> [LiveTranscriptPhrase] {
            values.sorted(by: LiveTranscriptPhrase.ordered).flatMap { phrase in
                let rows = speakerTimeline?.attributing(phrase, preceding: preceding[phrase.source]) ?? [phrase]
                preceding[phrase.source] = phrase
                return rows
            }
        }
        let resolvedFinal = attribute(phrases)
        let resolvedPending = attribute(partials)
        let raw = resolvedFinal.map { ($0, true) } + resolvedPending.map { ($0, false) }
        for (phrase, final) in raw {
            let covered = changes.filter { $0.anchor.overlaps(phrase) }
            var pieces = [(phrase.start, phrase.end)]
            for change in covered {
                pieces = pieces.flatMap { start, end -> [(Double, Double)] in
                    let left = max(start, change.anchor.start)
                    let right = min(end, change.anchor.end)
                    guard right > left else { return [(start, end)] }
                    return [(start, left), (right, end)].filter { $0.1 > $0.0 }
                }
            }
            guard !pieces.isEmpty else { continue }
            var rows: [LiveTranscriptPhrase] = []
            if covered.isEmpty {
                rows = [phrase]
            }
            else if phrase.hasCompleteWordTiming {
                rows = pieces.compactMap { start, end in phrase.fragment(start: start, end: end) }
            }
            else {
                var retained = phrase
                retained.id = phrase.fragmentID(suffix: "unaligned")
                retained.unresolvedTiming = true
                rows = [retained]
            }
            for var row in rows {
                row.recognizedFinal = final
                if final {
                    finalized.append(row)
                }
                else {
                    pending.append(row)
                }
            }
        }
        for change in changes {
            let matching = raw.filter { $0.0.overlaps(change.anchor) }
            guard change.text != nil || change.anchor.recognitionIsFinal || !matching.isEmpty else { continue }
            var row = change.anchor
            if let timeline = speakerTimeline {
                row.speakerIdentity = nil
                row.diarizationLabel = nil
                row.personID = nil
                row.voiceEmbedding = nil
                let attributed = timeline.attributing(row)
                if attributed.count == 1 {
                    row.speakerIdentity = attributed[0].speakerIdentity
                    row.diarizationLabel = attributed[0].diarizationLabel
                    row.personID = attributed[0].personID
                    row.voiceEmbedding = attributed[0].voiceEmbedding
                }
            }
            row.recognizedFinal = change.anchor.recognitionIsFinal || recognitionCovers(change.anchor)
            if let text = change.text {
                row.text = text
                row.words = []
                row.userEdited = true
            }
            else if !matching.isEmpty && matching.allSatisfy({ $0.0.hasCompleteWordTiming }) {
                let fragments = matching.map(\.0).sorted(by: LiveTranscriptPhrase.ordered).compactMap {
                    $0.fragment(start: max(row.start, $0.start), end: min(row.end, $0.end))
                }
                if !fragments.isEmpty {
                    // Preserve punctuation and spacing inside each raw ASR phrase.
                    // Speaker fragments may divide text where no space existed.
                    let originals = (phrases + partials).filter { $0.overlaps(change.anchor) }
                        .sorted(by: LiveTranscriptPhrase.ordered)
                    let originalSlices = originals.compactMap { phrase in
                        phrase.fragment(start: max(row.start, phrase.start), end: min(row.end, phrase.end))
                    }
                    let textSlices =
                        !originals.isEmpty && originalSlices.count == originals.count
                        ? originalSlices : fragments
                    row.text = LiveTranscriptParagraphs.joinedText(textSlices.map(\.text))
                    row.words = fragments.flatMap(\.words)
                    // Silence between recognized phrases is not unfinished text.
                    // This replacement contains only the matching raw words.
                    row.recognizedFinal = matching.allSatisfy(\.1)
                }
            }
            else if !matching.isEmpty
                && matching.allSatisfy({
                    $0.0.start >= row.start && $0.0.end <= row.end
                })
            {
                // An assignment changes identity, not recognized wording. When
                // complete raw phrases fit the anchor, no word splitting is needed.
                let latest = matching.map(\.0).sorted(by: LiveTranscriptPhrase.ordered)
                row.text = LiveTranscriptParagraphs.joinedText(latest.map(\.text))
                row.words = latest.flatMap(\.words)
                row.recognizedFinal = matching.allSatisfy(\.1)
            }
            else if change.text == nil && !matching.isEmpty {
                row.unresolvedTiming = true
            }
            if change.personWasAssigned {
                row.personID = change.personID
                // A range correction must not rename a later, different model identity.
                row.speakerIdentity = change.scopedSpeakerIdentity
                if let id = change.scopedSpeakerIdentity,
                    let speaker = speakerTimeline?.speakers.first(where: { $0.id == id })
                {
                    row.personID = speaker.personID
                    row.voiceEmbedding = speaker.voiceEmbedding
                    row.diarizationLabel = speaker.label
                }
                else {
                    row.voiceEmbedding = nil
                }
            }
            if row.recognitionIsFinal || row.isUserEdited {
                finalized.append(row)
            }
            else {
                pending.append(row)
            }
        }
        return (
            finalized.sorted(by: LiveTranscriptPhrase.ordered),
            pending.sorted(by: LiveTranscriptPhrase.ordered)
        )
    }

    private func recognitionCovers(_ anchor: LiveTranscriptPhrase) -> Bool {
        var edge = anchor.start
        for phrase in phrases.filter({ $0.overlaps(anchor) }).sorted(by: LiveTranscriptPhrase.ordered) {
            if phrase.start > edge { return false }
            edge = max(edge, phrase.end)
        }
        return edge >= anchor.end
    }

    static func read(at directory: URL, meetingID: UUID) throws -> Self? {
        let file = directory.appendingPathComponent("live-transcript.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard value.version == 1, value.meetingID == meetingID else {
            throw MeetingError.message("This live transcript uses an unsupported format.")
        }
        return value
    }

    func save(at directory: URL) throws {
        try PrivateTranscriptFile.write(try JSONEncoder().encode(self), name: "live-transcript.json", at: directory)
    }
}

enum LiveAudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, system
    var title: String { self == .microphone ? "Microphone" : "System Audio" }
}

struct LiveTranscriptPhrase: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var session: UUID
    var source: LiveAudioSource
    var start: Double
    var end: Double
    var text: String
    var words: [LiveTranscriptWord] = []
    var locale: String?
    var personID: UUID?
    var userEdited: Bool?
    var recognizedFinal: Bool?
    var unresolvedTiming: Bool?
    var speakerIdentity: UUID?
    var diarizationLabel: String?
    var voiceEmbedding: TypedVoiceEmbedding?
    var speakerLabel: String { diarizationLabel ?? (source == .microphone ? "mic_01" : "sys_01") }
    var isUserEdited: Bool { userEdited == true }
    var recognitionIsFinal: Bool { recognizedFinal ?? true }
    var hasUnresolvedTiming: Bool { unresolvedTiming == true }

    func overlaps(_ other: Self) -> Bool {
        source == other.source && session == other.session
            && (start == other.start || (start < other.end && end > other.start))
    }

    func preservingIdentity(from previous: [Self]) -> Self {
        var result = self
        if let match = previous.filter({ overlaps($0) }).max(by: {
            let left = min(end, $0.end) - max(start, $0.start)
            let right = min(end, $1.end) - max(start, $1.start)
            return left == right ? $0.start > $1.start : left < right
        }) {
            result.id = match.id
        }
        return result
    }

    var hasCompleteWordTiming: Bool {
        guard !words.isEmpty,
            words.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
                    && $0.start >= start && $0.end <= end
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else { return false }
        guard zip(words, words.dropFirst()).allSatisfy({ pair in pair.0.end <= pair.1.start }) else { return false }
        // Missing text runs cannot safely be discarded when splitting a phrase.
        let compact: (String) -> String = { $0.filter { !$0.isWhitespace } }
        return compact(words.map(\.text).joined()) == compact(text)
    }

    func fragment(start: Double, end: Double) -> Self? {
        let selected = words.filter {
            let midpoint = ($0.start + $0.end) / 2
            return midpoint >= start && midpoint < end
        }
        guard !selected.isEmpty else { return nil }
        var result = self
        result.id = fragmentID(suffix: String(start))
        result.start = start
        result.end = end
        result.words = selected
        var cursor = text.startIndex
        var ranges: [Range<String.Index>] = []
        for word in words {
            guard
                let range = text.range(
                    of: word.text.trimmingCharacters(in: .whitespacesAndNewlines), range: cursor..<text.endIndex)
            else { return nil }
            ranges.append(range)
            cursor = range.upperBound
        }
        let indices = words.indices.filter {
            let midpoint = (words[$0].start + words[$0].end) / 2
            return midpoint >= start && midpoint < end
        }
        guard let first = indices.first, let last = indices.last else { return nil }
        result.text = String(text[ranges[first].lowerBound..<ranges[last].upperBound])
        return result
    }

    func fragmentID(suffix: String) -> UUID {
        let hash = SHA256.hash(data: Data((id.uuidString + ":" + suffix).utf8))
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map {
            String(
                hex[
                    hex.index(
                        hex.startIndex, offsetBy: $0.lowerBound)..<hex.index(hex.startIndex, offsetBy: $0.upperBound)])
        }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }
    static func ordered(_ left: Self, _ right: Self) -> Bool {
        left.start == right.start ? left.source.rawValue < right.source.rawValue : left.start < right.start
    }
    static func replacingPartials(_ partials: [Self], with phrase: Self, final: Bool) -> [Self] {
        let retained = partials.filter { $0.source != phrase.source || $0.session != phrase.session }
        return final ? retained : retained + [phrase.preservingIdentity(from: partials)]
    }
}

struct LiveTranscriptOverride: Codable, Equatable, Identifiable {
    var anchor: LiveTranscriptPhrase
    var text: String?
    var personID: UUID?
    var personWasAssigned = false
    var scopedSpeakerIdentity: UUID?
    var id: UUID { anchor.id }
}

struct LiveTranscriptWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct LiveTranscriptGap: Codable, Equatable, Sendable {
    var source: LiveAudioSource
    var start: Double
    var end: Double
    var reason: String
}

extension LiveTranscriptPhrase {
    /// Hide anonymous model output without changing saved activity or named rows.
    func displayingSpeakerLabels(_ enabled: Bool, knownPeople: Set<UUID>? = nil) -> Self {
        var presented = self
        if let personID, let knownPeople, !knownPeople.contains(personID) {
            presented.personID = nil
        }
        guard !enabled, presented.personID == nil else { return presented }
        presented.diarizationLabel = nil
        presented.speakerIdentity = nil
        presented.voiceEmbedding = nil
        return presented
    }
}
