import CryptoKit
import Foundation

/// In-memory live processing state and compact recording checkpoint metadata.
struct LiveTranscriptDraft: Codable, Equatable, Sendable {
    var savedSegments: [TranscriptSegment]?
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
    var liveSources: [LiveAudioSource]?
    /// Effective streaming assignments are persisted independently of raw recognition.
    var effectivePhrases: [LiveTranscriptPhrase]?

    private var finalizedParagraphs: [LiveTranscriptPhrase] {
        if let savedSegments {
            let speakers = Dictionary(uniqueKeysWithValues: (speakerTimeline?.speakers ?? []).map { ($0.id, $0) })
            return savedSegments.map { segment in
                var row = LiveSpeakerAliases.applying(
                    segment.livePhrase(meetingID: meetingID),
                    aliases: speakerTimeline?.identityAliases ?? [:], speakers: speakers)
                if let id = row.speakerIdentity, let speaker = speakers[id] {
                    row.personID = speaker.personID
                    row.voiceEmbedding = speaker.voiceEmbedding
                    row.speakerColorSlot = speaker.colorSlot
                }
                return row
            }
        }
        return LiveTranscriptParagraphs.groups(
            finalized: resolvedRows().finalized.sorted(by: LiveTranscriptPhrase.ordered), partials: [],
            overrides: overrides ?? []
        ).map(\.phrase)
    }

    var segments: [TranscriptSegment] {
        if let savedSegments {
            let aliases = speakerTimeline?.identityAliases ?? [:]
            let speakers = Dictionary(uniqueKeysWithValues: (speakerTimeline?.speakers ?? []).map { ($0.id, $0) })
            return savedSegments.map { original in
                guard let old = original.speakerID, speakers[old]?.manuallyAssigned != true else { return original }
                let id = LiveSpeakerAliases.resolve(old, aliases: aliases)
                guard id != old, let speaker = speakers[id] else { return original }
                var value = original
                value.speakerID = id
                value.speaker = speaker.label
                value.personID = speaker.personID
                return value
            }
        }
        return finalizedParagraphs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            TranscriptSegment(live: $0)
        }
    }

    var speakers: [MeetingSpeaker] {
        var seen = Set<UUID>()
        return finalizedParagraphs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap {
                // Keep source rows separate so existing manual passage assignments
                // survive adoption without turning the source into a voice identity.
                let identity = $0.speakerIdentity ?? $0.id
                guard seen.insert(identity).inserted else { return nil }
                return MeetingSpeaker(
                    id: identity, label: $0.speakerLabel,
                    track: speakerTimeline?.speakers.first(where: { $0.id == identity })?.additionalSources?.isEmpty
                        == false
                        ? "multiple" : $0.source.rawValue,
                    providerName: provider, voiceEmbedding: $0.voiceEmbedding,
                    personID: $0.personID, confirmed: $0.personID != nil,
                    sourcePlaceholder: $0.hasSpeakerIdentity ? nil : $0.source,
                    manuallyAssigned: speakerTimeline?.speakers.first(where: { $0.id == identity })?.manuallyAssigned,
                    manualReviewThrough: speakerTimeline?.speakers.first(where: { $0.id == identity })?
                        .manualReviewThrough,
                    colorSlot: $0.resolvedSpeakerColorSlot)
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
        savedSegments = nil
        changeOverride(for: phrase) { $0.text = text }
    }

    mutating func assignPerson(_ personID: UUID?, for phrase: LiveTranscriptPhrase, speakerIdentity: UUID? = nil) {
        savedSegments = nil
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
    func resolvedRows(partials: [LiveTranscriptPhrase] = [], cache: LiveTranscriptResolutionCache? = nil) -> (
        finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase]
    ) {
        if let effectivePhrases {
            var effective = self
            let speakers = Dictionary(uniqueKeysWithValues: (speakerTimeline?.speakers ?? []).map { ($0.id, $0) })
            effective.phrases = effectivePhrases.map { original in
                var row = LiveSpeakerAliases.applying(
                    original,
                    aliases: speakerTimeline?.identityAliases ?? [:], speakers: speakers)
                if let identity = row.speakerIdentity, let speaker = speakers[identity] {
                    row.personID = speaker.personID
                    row.voiceEmbedding = speaker.voiceEmbedding
                }
                return row
            }
            effective.effectivePhrases = nil
            effective.speakerTimeline = nil
            return effective.resolvedRows(partials: partials, cache: cache)
        }
        let cache = cache ?? LiveTranscriptResolutionCache()
        cache.begin(meetingID: meetingID, timeline: speakerTimeline)
        defer { cache.finish() }
        let changes = overrides ?? []
        if changes.isEmpty { return cache.uneditedRows(finalized: phrases, partials: partials) }
        var finalized: [LiveTranscriptPhrase] = []
        var pending: [LiveTranscriptPhrase] = []
        var preceding: [LiveAudioSource: LiveTranscriptPhrase] = [:]
        func attribute(_ values: [LiveTranscriptPhrase]) -> [LiveTranscriptPhrase] {
            values.sorted(by: LiveTranscriptPhrase.ordered).flatMap { phrase in
                let rows = cache.attributing(phrase, preceding: preceding[phrase.source])
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
            row.keepsParagraphBoundary = true
            if speakerTimeline != nil {
                row.speakerIdentity = nil
                row.diarizationLabel = nil
                row.personID = nil
                row.voiceEmbedding = nil
                row.speakerColorSlot = nil
                let attributed = cache.attributing(row)
                if attributed.count == 1 {
                    row.speakerIdentity = attributed[0].speakerIdentity
                    row.diarizationLabel = attributed[0].diarizationLabel
                    row.personID = attributed[0].personID
                    row.voiceEmbedding = attributed[0].voiceEmbedding
                    row.speakerColorSlot = attributed[0].speakerColorSlot
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
                    row.speakerColorSlot = speaker.colorSlot
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

    /// Current transcript reads never replay recognition events or prefer old snapshots.
    static func read(at directory: URL, meetingID: UUID) throws -> Self? {
        if let saved = try LiveTranscriptProjection.read(at: directory, meetingID: meetingID) { return saved }
        _ = try TranscriptStorage.read(at: directory)
        return nil
    }

    static func recover(at directory: URL, meetingID: UUID) throws -> Self? {
        try read(at: directory, meetingID: meetingID)
    }

    func save(at directory: URL) throws {
        try TranscriptStorage.coordinated(at: directory) {
            let rows = segments
            let data = try TranscriptStorage.encoded(rows)
            var transaction = LibraryFileTransaction(root: directory)
            do {
                try transaction.remember(directory.appendingPathComponent(TranscriptStorage.filename))
                try transaction.remember(directory.appendingPathComponent(LiveTranscriptProjection.checkpointName))
                try PrivateTranscriptFile.write(data, name: TranscriptStorage.filename, at: directory)
                var metadata = self
                metadata.phrases = []
                metadata.effectivePhrases = nil
                metadata.savedSegments = nil
                metadata.overrides = nil
                metadata.speakerTimeline?.intervals = []
                let checkpoint = LiveTranscriptProjection.Checkpoint(
                    bytes: UInt64(data.count), rows: rows.count,
                    draft: metadata, segments: [], finished: true)
                try PrivateTranscriptFile.write(
                    try JSONEncoder().encode(checkpoint), name: LiveTranscriptProjection.checkpointName, at: directory)
                try transaction.commit()
            }
            catch {
                try transaction.restore()
                throw error
            }
        }
    }

}

enum LiveAudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, system
    var title: String { self == .microphone ? "Microphone" : "System Audio" }
    var shortLabel: String { self == .microphone ? "mic" : "sys" }
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
    var keepsParagraphBoundary: Bool?
    var speakerIdentity: UUID?
    var diarizationLabel: String?
    var voiceEmbedding: TypedVoiceEmbedding?
    var speakerColorSlot: Int?
    var resolvedSpeakerColorSlot: Int? {
        if let speakerColorSlot { return speakerColorSlot }
        return hasSpeakerIdentity ? nil : (source == .microphone ? 0 : 1)
    }
    var speakerLabel: String { diarizationLabel ?? source.shortLabel }
    var hasSpeakerIdentity: Bool { speakerIdentity != nil }
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

struct LiveTranscriptOverride: Codable, Equatable, Identifiable, Sendable {
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
        presented.speakerColorSlot = nil
        return presented
    }
}

/// Caches attribution only. Manual text/person overrides are reapplied on every
/// resolution, so edits and late recognition revisions retain their semantics.
final class LiveTranscriptResolutionCache {
    private struct Entry {
        let phrase: LiveTranscriptPhrase
        let preceding: LiveTranscriptPhrase?
        let evidence: LiveSpeakerTimeline
        let rows: [LiveTranscriptPhrase]
    }
    private var meetingID: UUID?
    private var timeline: LiveSpeakerTimeline?
    private var index: LiveSpeakerIntervalIndex?
    private var entries: [UUID: Entry] = [:]
    private var visited: Set<UUID> = []
    private(set) var attributionCount = 0
    private var finalizedInput: [LiveTranscriptPhrase] = []
    private var finalizedOutput: [LiveTranscriptPhrase] = []
    private var finalizedPreceding: [LiveAudioSource: LiveTranscriptPhrase] = [:]
    private var finalizedIDs: Set<UUID> = []
    private var finalizedTimeline: LiveSpeakerTimeline?
    private var finalizedEnd = 0.0
    private var finalizedLast: LiveTranscriptPhrase?
    private var transientIDs: Set<UUID> = []
    private var keepsFinalizedEntries = false
    private(set) var finalizedAssemblyCount = 0

    func begin(meetingID: UUID, timeline: LiveSpeakerTimeline?) {
        if self.meetingID != meetingID {
            entries.removeAll()
            finalizedInput = []
            finalizedOutput = []
            finalizedPreceding = [:]
            finalizedIDs = []
            finalizedEnd = 0
            finalizedLast = nil
            transientIDs = []
            finalizedTimeline = nil
            self.meetingID = meetingID
        }
        keepsFinalizedEntries = false
        finalizedAssemblyCount = 0
        if self.timeline != timeline {
            self.timeline = timeline
            if let timeline, index != nil {
                index?.update(timeline)
            }
            else {
                index = timeline.map(LiveSpeakerIntervalIndex.init)
            }
        }
        visited.removeAll(keepingCapacity: true)
        attributionCount = 0
    }

    func attributing(_ phrase: LiveTranscriptPhrase, preceding: LiveTranscriptPhrase? = nil) -> [LiveTranscriptPhrase] {
        guard let index else { return [phrase] }
        visited.insert(phrase.id)
        let evidence = index.evidence(for: phrase, preceding: preceding)
        if let entry = entries[phrase.id], entry.phrase == phrase, entry.preceding == preceding,
            entry.evidence == evidence
        {
            return entry.rows
        }
        attributionCount += 1
        let rows = evidence.attributing(phrase, preceding: preceding)
        entries[phrase.id] = Entry(phrase: phrase, preceding: preceding, evidence: evidence, rows: rows)
        return rows
    }

    func uneditedRows(finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase]) -> (
        finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase]
    ) {
        keepsFinalizedEntries = true
        let sameEvidence = Self.keepsEvidence(finalizedTimeline, timeline, through: finalizedEnd)
        let prefixUnchanged =
            finalized == finalizedInput
            || finalized.count > finalizedInput.count
                && finalized.prefix(finalizedInput.count).elementsEqual(finalizedInput)
        let added = Array(finalized.dropFirst(finalizedInput.count))
        let appendOrdered = added.enumerated().allSatisfy { offset, phrase in
            let previous = offset > 0 ? added[offset - 1] : finalizedLast
            return previous.map { LiveTranscriptPhrase.ordered($0, phrase) } ?? true
        }
        if !(sameEvidence && prefixUnchanged && appendOrdered) {
            let ids = Set(finalized.map(\.id))
            for id in finalizedIDs.subtracting(ids) { entries.removeValue(forKey: id) }
            finalizedInput = []
            finalizedOutput = []
            finalizedPreceding = [:]
            finalizedIDs = []
            finalizedEnd = 0
            finalizedLast = nil
        }
        let remaining = finalized.dropFirst(finalizedInput.count).sorted(by: LiveTranscriptPhrase.ordered)
        let previousOutputCount = finalizedOutput.count
        for phrase in remaining {
            let attributed = attributing(phrase, preceding: finalizedPreceding[phrase.source]).map {
                var row = $0
                row.recognizedFinal = true
                return row
            }
            finalizedOutput.append(contentsOf: attributed)
            finalizedPreceding[phrase.source] = phrase
            finalizedIDs.insert(phrase.id)
            finalizedEnd = max(finalizedEnd, phrase.end)
            finalizedLast = phrase
            finalizedAssemblyCount += 1
        }
        finalizedInput = finalized
        finalizedTimeline = timeline
        // Full rebuilds can split overlapping source phrases, whose fragments
        // need timeline ordering. Appended fragments remain ordered normally.
        if finalizedAssemblyCount > 0 {
            let changedStart = max(0, previousOutputCount - 1)
            let tail = finalizedOutput[changedStart...]
            if !zip(tail, tail.dropFirst()).allSatisfy({ LiveTranscriptPhrase.ordered($0, $1) }) {
                finalizedOutput.sort(by: LiveTranscriptPhrase.ordered)
            }
        }
        var preceding = finalizedPreceding
        let pending = partials.sorted(by: LiveTranscriptPhrase.ordered).flatMap { phrase in
            let rows = attributing(phrase, preceding: preceding[phrase.source])
            preceding[phrase.source] = phrase
            return rows.map {
                var row = $0
                row.recognizedFinal = false
                return row
            }
        }.sorted(by: LiveTranscriptPhrase.ordered)
        return (finalizedOutput, pending)
    }

    private static func keepsEvidence(
        _ previous: LiveSpeakerTimeline?, _ current: LiveSpeakerTimeline?, through end: Double
    ) -> Bool {
        if previous == current { return true }
        guard let previous, let current, previous.speakers == current.speakers else { return false }
        guard previous.gaps.filter({ $0.start < end }) == current.gaps.filter({ $0.start < end }),
            previous.intervals.count <= current.intervals.count
        else { return false }
        for (old, new) in zip(previous.intervals, current.intervals) {
            guard old.speakerID == new.speakerID, old.start == new.start,
                min(old.end, end) == min(new.end, end)
            else { return false }
        }
        guard current.intervals.dropFirst(previous.intervals.count).allSatisfy({ $0.start >= end }) else {
            return false
        }
        for source in [LiveAudioSource.microphone, .system] {
            let old = previous.cursors.first { $0.source == source }
            let new = current.cursors.first { $0.source == source }
            guard
                old == nil && new == nil
                    || old != nil && new != nil
                        && min(old!.end, end) == min(new!.end, end)
            else { return false }
        }
        return true
    }

    func finish() {
        if keepsFinalizedEntries {
            for id in transientIDs where !visited.contains(id) { entries.removeValue(forKey: id) }
            transientIDs = visited.subtracting(finalizedIDs)
        }
        else {
            entries = entries.filter { visited.contains($0.key) }
            finalizedInput = []
            finalizedOutput = []
            finalizedIDs = []
            finalizedPreceding = [:]
            finalizedTimeline = nil
            finalizedEnd = 0
            finalizedLast = nil
            transientIDs = visited
        }
    }
}
