import Foundation

/// A reference-owned, append-only cold prefix and a bounded mutable recognition tail.
/// Published revisions describe mutations; readers never compare historical arrays.
final class LiveTranscriptStream {
    static let maximumLabelWait = 30.0
    private(set) var revision = 0
    private(set) var resetRevision = 0
    private(set) var frozenCount = 0
    private(set) var hotFinalized: [LiveTranscriptPhrase] = []
    private(set) var hotPartials: [LiveTranscriptPhrase] = []
    private(set) var attributedPhraseCount = 0
    private var frozen: [LiveTranscriptPhrase] = []
    private var displayedFrozen: [LiveTranscriptPhrase]?
    private var overrides: [LiveTranscriptOverride] = []
    private var frozenOverrideIDs = Set<UUID>()
    private var activeOverrides: [LiveTranscriptOverride] = []
    private var overrideIDs = Set<UUID>()
    private var identityAliases: [UUID: UUID] = [:]
    private var speakerMetadata: [UUID: LiveSpeakerIdentity] = [:]
    private var snapshotHead: LiveTranscriptFrozenBlock?
    private var snapshotTail: [LiveTranscriptPhrase] = []
    private var pending: [LiveTranscriptPhrase] = []
    private var partials: [LiveTranscriptPhrase] = []
    private var timeline = LiveSpeakerTimeline()
    private var previous: [LiveAudioSource: LiveTranscriptPhrase] = [:]
    private struct RecognitionSource: Hashable {
        var source: LiveAudioSource
        var session: UUID
    }
    private var sealedThrough: [LiveAudioSource: Double] = [:]
    private var sealedRecognition: [RecognitionSource: Double] = [:]
    private var latestTime = 0.0
    private var observationIdentity = false
    private var labeling = false
    private var sources: [LiveAudioSource] = [.system]
    private var recognitionEnds: [LiveAudioSource: Double] = [:]
    private var carryReset: [LiveAudioSource: Double] = [:]

    func frozenRow(at index: Int) -> LiveTranscriptPhrase {
        let row = displayedFrozen?[index] ?? frozen[index]
        guard !overrides.contains(where: { $0.personWasAssigned && row.overlaps($0.anchor) }) else { return row }
        return LiveSpeakerAliases.applying(row, aliases: identityAliases, speakers: speakerMetadata)
    }

    func updateEdits(_ overrides: [LiveTranscriptOverride], speakers: [LiveSpeakerIdentity]) {
        self.overrides = overrides
        activeOverrides = overrides
        overrideIDs = Set(overrides.map(\.id))
        speakerMetadata = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        for index in timeline.speakers.indices {
            if let updated = speakerMetadata[timeline.speakers[index].id] { timeline.speakers[index] = updated }
        }
        frozenOverrideIDs = []
        displayedFrozen = applyEdits(frozen)
        frozenOverrideIDs = Set(displayedFrozen!.map(\.id)).intersection(overrideIDs)
        frozenCount = displayedFrozen!.count
        resetRevision += 1
        refresh()
    }

    private func applyEdits(_ rows: [LiveTranscriptPhrase], omitFrozenOverrides: Bool = false) -> [LiveTranscriptPhrase]
    {
        guard !overrides.isEmpty || !speakerMetadata.isEmpty else { return rows }
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "")
        draft.phrases = rows.map { original in
            var row = original
            if let id = row.speakerIdentity, let speaker = speakerMetadata[id] {
                row.personID = speaker.personID
                row.voiceEmbedding = speaker.voiceEmbedding
            }
            return row
        }
        let applicable = omitFrozenOverrides ? activeOverrides : overrides
        draft.overrides = applicable.filter { change in rows.contains { $0.overlaps(change.anchor) } }
        return draft.resolvedRows().finalized.filter { !omitFrozenOverrides || !frozenOverrideIDs.contains($0.id) }
    }

    func reset(labeling: Bool, sources: [LiveAudioSource] = [.system]) {
        frozen = []
        displayedFrozen = nil
        overrides = []
        activeOverrides = []
        overrideIDs = []
        frozenOverrideIDs = []
        speakerMetadata = [:]
        identityAliases = [:]
        frozenCount = 0
        snapshotHead = nil
        snapshotTail = []
        pending = []
        partials = []
        timeline = LiveSpeakerTimeline()
        observationIdentity = false
        previous = [:]
        sealedThrough = [:]
        sealedRecognition = [:]
        latestTime = 0
        self.sources = sources
        recognitionEnds = [:]
        carryReset = [:]
        self.labeling = labeling
        hotFinalized = []
        hotPartials = []
        resetRevision += 1
        revision += 1
    }

    func setLabeling(_ enabled: Bool) {
        labeling = enabled
        refresh()
    }

    func prepare(_ phrase: LiveTranscriptPhrase) -> LiveTranscriptPhrase? {
        phrase.after(sealedRecognition[.init(source: phrase.source, session: phrase.session)] ?? -1)
    }

    func accept(_ incoming: LiveTranscriptPhrase, final: Bool) {
        guard incoming.isAdmissible else { return }
        guard let phrase = prepare(incoming) else { return }
        latestTime = max(latestTime, phrase.end)
        partials.removeAll { $0.source == phrase.source && $0.session == phrase.session }
        if final {
            recognitionEnds[phrase.source] = max(recognitionEnds[phrase.source] ?? 0, phrase.end)
            // Already sealed words in this recognition session remain immutable.
            pending.removeAll { $0.overlaps(phrase) }
            pending.append(phrase)
        }
        else {
            let cutoff = latestTime - Self.maximumLabelWait
            if phrase.start < cutoff, phrase.hasCompleteWordTiming,
                let boundary = phrase.words.last(where: { $0.end <= cutoff })?.end,
                let prefix = phrase.fragment(start: phrase.start, end: boundary)
            {
                var stable = prefix
                stable.recognizedFinal = false
                pending.removeAll { $0.overlaps(stable) }
                pending.append(stable)
                recognitionEnds[phrase.source] = max(recognitionEnds[phrase.source] ?? 0, stable.end)
                if let suffix = phrase.after(stable.end) { partials.append(suffix) }
            }
            else {
                partials.append(phrase)
            }
        }
        refresh()
    }

    func accept(_ event: LiveSpeakerEvent) {
        guard timeline.accept(event) else { return }
        latestTime = max(latestTime, event.end)
        refresh()
    }

    func replaceObservationTimeline(_ value: LiveSpeakerTimeline) {
        observationIdentity = true
        if identityAliases != (value.identityAliases ?? [:]) { resetRevision += 1 }
        identityAliases = value.identityAliases ?? [:]
        speakerMetadata = Dictionary(uniqueKeysWithValues: value.speakers.map { ($0.id, $0) })
        timeline = value
        latestTime = max(latestTime, value.cursors.map(\.end).max() ?? 0)
        refresh()
    }

    func accept(_ gap: LiveTranscriptGap) {
        timeline.gaps.append(gap)
        carryReset[gap.source] = max(carryReset[gap.source] ?? 0, gap.end)
        latestTime = max(latestTime, gap.end)
        refresh()
    }

    func discardPartials() {
        partials = []
        refresh()
    }

    func finish() {
        partials = []
        refresh(finishing: true)
    }

    var snapshot: LiveTranscriptEffectiveSnapshot {
        .init(
            head: snapshotHead, tail: snapshotTail + hotFinalized, identityAliases: identityAliases,
            speakers: speakerMetadata)
    }

    private func refresh(finishing: Bool = false) {
        let interval = RecordingSignposts.signposter.beginInterval(
            "Refresh live transcript", id: RecordingSignposts.signposter.makeSignpostID())
        defer { RecordingSignposts.signposter.endInterval("Refresh live transcript", interval) }
        attributedPhraseCount = 0
        pending.sort(by: LiveTranscriptPhrase.ordered)
        var carry = previous
        var ready: [(LiveTranscriptPhrase, [LiveTranscriptPhrase])] = []
        var hot: [LiveTranscriptPhrase] = []
        var retained: [LiveTranscriptPhrase] = []
        var canSeal = true
        let recognitionCutoff = sources.map { recognitionEnds[$0] ?? 0 }.min() ?? latestTime
        for phrase in pending {
            if let reset = carryReset[phrase.source], phrase.end > reset,
                (carry[phrase.source]?.end ?? 0) <= reset
            {
                carry.removeValue(forKey: phrase.source)
            }
            let observed = labeling ? timeline.attributing(phrase, bridgeUnknownWords: false) : [phrase]
            attributedPhraseCount += 1
            var effective =
                observationIdentity
                ? observed : Self.carryForward(observed, previous: &carry, timeline: timeline, labeling: labeling)
            let cursor = timeline.cursors.first { $0.source == phrase.source }?.end ?? -1
            let cutoff = max(
                labeling
                    ? min(observationIdentity ? cursor - Self.maximumLabelWait : cursor, recognitionCutoff)
                    : recognitionCutoff,
                latestTime - Self.maximumLabelWait)
            // Seal a chronological prefix only. This preserves native row positions.
            let sealed = finishing || phrase.end <= cutoff
            if canSeal && sealed {
                effective = effective.map { original in
                    var row = original
                    row.recognizedFinal = true
                    return row
                }
                ready.append((phrase, effective))
            }
            else {
                canSeal = false
                retained.append(phrase)
                hot.append(contentsOf: effective)
            }
        }
        for (phrase, effective) in ready {
            frozen.append(contentsOf: effective)
            if displayedFrozen != nil {
                let additions = applyEdits(effective, omitFrozenOverrides: true)
                displayedFrozen?.append(contentsOf: additions)
                frozenOverrideIDs.formUnion(Set(additions.map(\.id)).intersection(overrideIDs))
            }
            snapshotTail.append(contentsOf: effective)
            if let last = effective.last { previous[phrase.source] = last }
            sealedThrough[phrase.source] = max(sealedThrough[phrase.source] ?? 0, phrase.end)
            let recognition = RecognitionSource(source: phrase.source, session: phrase.session)
            sealedRecognition[recognition] = max(sealedRecognition[recognition] ?? 0, phrase.end)
        }
        frozenCount = displayedFrozen?.count ?? frozen.count
        if snapshotTail.count >= 64 {
            snapshotHead = LiveTranscriptFrozenBlock(previous: snapshotHead, rows: snapshotTail)
            snapshotTail = []
        }
        activeOverrides.removeAll { change in
            frozenOverrideIDs.contains(change.id) && change.anchor.end <= (sealedThrough[change.anchor.source] ?? -1)
        }
        pending = retained
        hotFinalized = applyEdits(hot, omitFrozenOverrides: true)
        hotPartials = partials.sorted(by: LiveTranscriptPhrase.ordered).flatMap { phrase in
            if let reset = carryReset[phrase.source], phrase.end > reset,
                (carry[phrase.source]?.end ?? 0) <= reset
            {
                carry.removeValue(forKey: phrase.source)
            }
            attributedPhraseCount += 1
            let observed = labeling ? timeline.attributing(phrase, bridgeUnknownWords: false) : [phrase]
            return observationIdentity
                ? observed : Self.carryForward(observed, previous: &carry, timeline: timeline, labeling: labeling)
        }
        if !activeOverrides.isEmpty {
            var edits = LiveTranscriptDraft(meetingID: UUID(), locale: "")
            edits.overrides = activeOverrides.filter { change in hotPartials.contains { $0.overlaps(change.anchor) } }
            let resolved = edits.resolvedRows(partials: hotPartials)
            let finalizedIDs = Set(hotFinalized.map(\.id))
            hotPartials = (resolved.finalized + resolved.partials).filter {
                !frozenOverrideIDs.contains($0.id) && !finalizedIDs.contains($0.id)
            }
        }
        // Keep only activity that can still affect the hot window. Frozen labels
        // already live in immutable snapshot blocks.
        let oldest = min(
            latestTime - Self.maximumLabelWait,
            min(pending.map(\.start).min() ?? latestTime, partials.map(\.start).min() ?? latestTime))
        timeline.intervals.removeAll { $0.end < oldest }
        timeline.gaps.removeAll { $0.end < oldest }
        revision += 1
    }

    static func carryForward(
        _ rows: [LiveTranscriptPhrase], previous: inout [LiveAudioSource: LiveTranscriptPhrase],
        timeline: LiveSpeakerTimeline, labeling: Bool = true
    ) -> [LiveTranscriptPhrase] {
        rows.map { original in
            var row = original
            if labeling {
                let preceding = previous[row.source]
                let blocked =
                    preceding.map { prior in
                        prior.session != row.session
                            || timeline.gaps.contains {
                                $0.source == row.source && $0.start < row.end && $0.end > prior.end
                            }
                            || timeline.cursors.first(where: { $0.source == row.source }).map { cursor in
                                guard let identity = prior.speakerIdentity,
                                    let speaker = timeline.speakers.first(where: { $0.id == identity })
                                else { return false }
                                return cursor.generation != speaker.generation && row.start >= prior.end
                            } == true
                    } ?? false
                if row.speakerIdentity == nil {
                    if let preceding, !blocked, preceding.speakerIdentity != nil {
                        row.speakerIdentity = preceding.speakerIdentity
                        row.diarizationLabel = preceding.diarizationLabel
                        row.personID = preceding.personID
                        row.voiceEmbedding = preceding.voiceEmbedding
                        row.speakerColorSlot = preceding.speakerColorSlot
                    }
                    else {
                        // An empty label is a source with no detected voice yet.
                        row.diarizationLabel = ""
                    }
                }
            }
            previous[row.source] = row
            return row
        }
    }
}

/// Persistent immutable blocks make a checkpoint snapshot constant time on the UI actor.
final class LiveTranscriptFrozenBlock: Sendable {
    let previous: LiveTranscriptFrozenBlock?
    let rows: [LiveTranscriptPhrase]
    init(previous: LiveTranscriptFrozenBlock?, rows: [LiveTranscriptPhrase]) {
        self.previous = previous
        self.rows = rows
    }
}

struct LiveTranscriptEffectiveSnapshot: Sendable {
    let head: LiveTranscriptFrozenBlock?
    let tail: [LiveTranscriptPhrase]
    var identityAliases: [UUID: UUID] = [:]
    var speakers: [UUID: LiveSpeakerIdentity] = [:]

    var phrases: [LiveTranscriptPhrase] {
        Self.materialize(head, tail: tail).map { row in
            return LiveSpeakerAliases.applying(row, aliases: identityAliases, speakers: speakers)
        }
    }

    private static func materialize(_ head: LiveTranscriptFrozenBlock?, tail: [LiveTranscriptPhrase])
        -> [LiveTranscriptPhrase]
    {
        var blocks: [LiveTranscriptFrozenBlock] = []
        var block = head
        while let current = block {
            blocks.append(current)
            block = current.previous
        }
        return blocks.reversed().flatMap(\.rows) + tail
    }
}

extension LiveTranscriptPhrase {
    var isAdmissible: Bool {
        start.isFinite && end.isFinite && start >= 0 && end >= start
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Trim a repeated ASR prefix using timed words and a backwards text walk.
    /// Work is proportional to the retained suffix, not the old utterance length.
    func after(_ cutoff: Double) -> Self? {
        guard end > cutoff else { return nil }
        guard start < cutoff, !words.isEmpty else { return self }
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if (words[middle].start + words[middle].end) / 2 < cutoff {
                low = middle + 1
            }
            else {
                high = middle
            }
        }
        guard low < words.count else { return nil }
        let selected = Array(words[low...])
        var cursor = text.endIndex
        var first = cursor
        for word in selected.reversed() {
            guard
                let range = text.range(
                    of: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    options: .backwards, range: text.startIndex..<cursor)
            else { return self }
            first = range.lowerBound
            cursor = range.lowerBound
        }
        var row = self
        row.id = fragmentID(suffix: String(selected[0].start))
        row.start = selected[0].start
        row.words = selected
        row.text = String(text[first...])
        return row
    }
}
