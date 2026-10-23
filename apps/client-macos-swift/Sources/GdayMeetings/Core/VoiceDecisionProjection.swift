import Foundation

/// Immutable projection input keeps audio checks and transcript traversal off the UI actor.
enum VoiceDecisionProjection {
    static func apply(
        to meeting: Meeting, evidence: [VoiceExample], decisions: [VoiceSpeakerDecision], deletedPeople: Set<UUID>,
        policy: VoiceMatchingPolicy = .default
    ) -> Meeting {
        let interval = ReviewPerformance.signposter.beginInterval(
            "Project voice decisions", id: ReviewPerformance.signposter.makeSignpostID())
        defer { ReviewPerformance.signposter.endInterval("Project voice decisions", interval) }
        var updated = meeting
        let projections = updated.speakers.filter { $0.voiceReviewOrigin != nil }
        if evidence.isEmpty, projections.isEmpty, !decisions.contains(where: { $0.meetingID == meeting.id }) {
            return meeting
        }
        let baseIDs = Set(updated.speakers.filter { $0.voiceReviewOrigin == nil }.map(\.id))
        var restoredSpeakers: [MeetingSpeaker] = []
        var restoredIDs = Set<UUID>()
        for projection in updated.speakers {
            guard let origin = projection.voiceReviewOrigin else {
                if restoredIDs.insert(projection.id).inserted { restoredSpeakers.append(projection) }
                continue
            }
            if origin.evidenceOnly == true { continue }
            var restored = projection
            restored.id = origin.speakerID
            restored.personID = origin.personID
            restored.manuallyAssigned = origin.manuallyAssigned
            restored.manualReviewThrough = origin.manualReviewThrough
            restored.confidence = origin.confidence
            restored.voiceReviewOrigin = nil
            restored.voiceReviewExampleID = nil
            if !baseIDs.contains(restored.id), restoredIDs.insert(restored.id).inserted {
                restoredSpeakers.append(restored)
            }
            for index in updated.transcript.indices where updated.transcript[index].speakerID == projection.id {
                updated.transcript[index].speakerID = origin.speakerID
            }
        }
        updated.speakers = restoredSpeakers
        let meetingDecisions = decisions.filter { $0.meetingID == meeting.id }.map { value in
            var decision = value
            decision.speakerID =
                projections.first(where: { $0.id == value.speakerID })?.voiceReviewOrigin?.speakerID
                ?? value.speakerID
            return decision
        }
        for decision in meetingDecisions {
            guard let index = updated.speakers.firstIndex(where: { $0.id == decision.speakerID }) else { continue }
            // Keep the pre-attribution baseline while a speaker-wide decision
            // is active. Undo can then restore derived identity rather than
            // leaving the last manually saved name behind.
            if let origin = projections.first(where: {
                $0.voiceReviewOrigin?.speakerID == decision.speakerID
                    && $0.voiceReviewOrigin?.evidenceOnly != true && $0.passageAssignmentOrigin == nil
            })?.voiceReviewOrigin {
                updated.speakers[index].voiceReviewOrigin = origin
                updated.speakers[index].voiceReviewOrigin?.transcriptAssociationTier = nil
            }
            if updated.speakers[index].voiceReviewOrigin == nil,
                updated.speakers[index].independentTurnAttribution == true
            {
                let baseline = updated.speakers[index]
                updated.speakers[index].voiceReviewOrigin = .init(
                    speakerID: baseline.id, personID: baseline.personID,
                    manuallyAssigned: baseline.manuallyAssigned, confidence: baseline.confidence,
                    manualReviewThrough: baseline.manualReviewThrough)
            }
            updated.speakers[index].personID = decision.personID
            updated.speakers[index].manuallyAssigned = true
            updated.speakers[index].confidence = nil
        }
        for index in updated.speakers.indices {
            if let personID = updated.speakers[index].personID, deletedPeople.contains(personID) {
                updated.speakers[index].personID = nil
            }
        }
        // A reviewed excerpt identifies its detected speaker. Keep the full
        // speaker attribution derived and reversible; exact passage decisions
        // below can still override it without enrolling machine evidence.
        let turnSpeakers = turnSpeakerScopes(evidence, meeting: updated)
        applySpeakerAssociations(
            to: &updated, evidence: evidence, deletedPeople: deletedPeople, policy: policy, turnSpeakers: turnSpeakers)
        let originalUsed = Set(updated.transcript.compactMap(\.speakerID))
        for index in updated.transcript.indices {
            let row = updated.transcript[index]
            guard row.end > row.start,
                let speaker = updated.speakers.first(where: { $0.id == row.speakerID })
            else { continue }
            // Reference review and explicit transcript attribution have separate
            // purposes. A saved speaker decision governs its transcript rows;
            // passage corrections use their own speaker identity and remain intact.
            if speaker.passageAssignmentOrigin != nil { continue }
            let baseID = speaker.voiceReviewOrigin?.speakerID ?? speaker.id
            if meetingDecisions.contains(where: { $0.speakerID == baseID }) { continue }
            let file = audioFile(for: row, speaker: speaker, meeting: updated)
            let relevant = evidence.filter {
                guard !$0.excluded, let range = $0.range, range.audioFile == file else { return false }
                if let turn = $0.attributionTurn {
                    guard turn.isValid, turnSpeakers[$0.id] == baseID, row.associationUncertain != true,
                        turn.start <= row.start, row.end <= turn.end
                    else { return false }
                    if $0.review == .confirmed || $0.manuallyCleared { return true }
                    guard speaker.manuallyAssigned != true, let association = $0.transcriptAssociation else {
                        return false
                    }
                    return association.isValid && association.policy.normalized == policy.normalized
                        && !deletedPeople.contains(association.personID)
                        && !$0.rejectedPersonIDs.contains(association.personID)
                }
                let applies =
                    $0.review == .confirmed || $0.manuallyCleared
                    || speaker.personID.map($0.rejectedPersonIDs.contains) == true
                return applies && range.contains(start: row.start, end: row.end)
            }
            let ranked = relevant.sorted {
                let leftConfirmed = $0.review == .confirmed
                let rightConfirmed = $1.review == .confirmed
                if leftConfirmed != rightConfirmed { return leftConfirmed }
                let leftTentative = $0.transcriptAssociation?.tier == .tentative
                let rightTentative = $1.transcriptAssociation?.tier == .tentative
                if leftTentative != rightTentative { return leftTentative }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let first = ranked.first else { continue }
            let confirmedPeople = Set(relevant.filter { $0.review == .confirmed }.map(\.personID))
            let machinePeople = Set(
                relevant.compactMap { $0.attributionTurn == nil ? nil : $0.transcriptAssociation?.personID })
            var people: Set<UUID?> = confirmedPeople.isEmpty ? Set(machinePeople.map(Optional.some)) : confirmedPeople
            if people.isEmpty || (confirmedPeople.isEmpty && relevant.contains(where: \.manuallyCleared)) {
                people.insert(nil)
            }
            // A negative answer about one person cannot contradict positive
            // evidence for somebody else covering the same passage.
            if relevant.contains(where: { example in
                confirmedPeople.contains { person in
                    person.map(example.rejectedPersonIDs.contains) == true
                }
            }) {
                people.insert(nil)
            }
            // Reviewing examples during a whole-label assignment confirms that
            // same decision; it does not create a distinct voice for each passage.
            // Conflicting or different exact-time reviews still need a projection.
            let exactLegacyCorrection =
                row.associationUncertain == true && first.review == .confirmed
                && first.attributionTurn == nil && speaker.voiceReviewOrigin?.personID != nil
                && speaker.voiceReviewOrigin?.personID != speaker.personID
            if speaker.manuallyAssigned == true || speaker.voiceReviewOrigin != nil,
                !exactLegacyCorrection, people.count == 1,
                people.first! == speaker.personID,
                speaker.voiceReviewOrigin?.transcriptAssociationTier != .tentative
            {
                continue
            }
            var assigned = speaker
            let sharesTurnIdentity = first.attributionTurn != nil && people.count == 1 && people.first! != nil
            assigned.id = VoiceProjectionOrigin.identity(
                exampleID: first.id, segmentID: sharesTurnIdentity ? meeting.id : row.id)
            // Saving allocates colors for distinct projected voices. Preserve
            // that passage's saved slot when rebuilding its projection, rather
            // than copying the first restored origin's slot onto every voice.
            // Otherwise reading the meeting repeatedly undoes save's allocation.
            if let prior = meeting.speakers.first(where: { $0.id == assigned.id }) {
                assigned.colorSlot = prior.colorSlot
            }
            // Flatten an existing whole-speaker projection so removing its
            // evidence also removes that identity from passage overrides.
            let baseline =
                speaker.voiceReviewOrigin
                ?? VoiceProjectionOrigin(
                    speakerID: speaker.id, personID: speaker.personID,
                    manuallyAssigned: speaker.manuallyAssigned, confidence: speaker.confidence,
                    manualReviewThrough: speaker.manualReviewThrough)
            assigned.voiceReviewOrigin = baseline
            assigned.voiceReviewOrigin?.transcriptAssociationTier =
                confirmedPeople.isEmpty ? first.transcriptAssociation?.tier : nil
            assigned.voiceReviewExampleID = first.id
            assigned.personID = people.count == 1 ? people.first! : nil
            assigned.manuallyAssigned = false
            assigned.manualReviewThrough = nil
            assigned.confidence = nil
            if !updated.speakers.contains(where: { $0.id == assigned.id }) { updated.speakers.append(assigned) }
            updated.transcript[index].speakerID = assigned.id
        }
        let used = Set(updated.transcript.compactMap(\.speakerID))
        let turnBaseIDs = Set(turnSpeakers.values)
        updated.speakers.removeAll {
            originalUsed.contains($0.id) && !used.contains($0.id) && !turnBaseIDs.contains($0.id)
        }
        // Discovery evidence is independent of transcript-local speaker IDs.
        // Keep confirmed attendance even when transcription has no speaker labels,
        // or the excerpt covers only part of a transcript row. Never fabricate a
        // transcript assignment from an excerpt which does not cover that row.
        let represented = Set(updated.speakers.compactMap(\.attendancePersonID))
        let conflicting = VoiceReviewConflicts.confirmedExampleIDs(in: evidence)
        let confirmed = evidence.filter {
            $0.review == .confirmed && !$0.excluded && !$0.manuallyCleared
                && !conflicting.contains($0.id)
                && $0.personID.map { !deletedPeople.contains($0) } == true
        }
        for example in confirmed where !represented.contains(example.personID!) {
            guard let range = example.range else { continue }
            var speaker = MeetingSpeaker(
                label: "Reviewed Voice", track: example.source, providerName: "Voice Review")
            speaker.id = VoiceProjectionOrigin.identity(exampleID: example.id, segmentID: meeting.id)
            speaker.personID = example.personID
            speaker.voiceSampleRange = range
            speaker.voiceSampleRevision = example.audioRevision
            speaker.manuallyAssigned = true
            speaker.voiceReviewExampleID = example.id
            speaker.voiceReviewOrigin = .init(speakerID: example.speakerID, evidenceOnly: true)
            if let prior = meeting.speakers.first(where: { $0.id == speaker.id }) {
                speaker.colorSlot = prior.colorSlot
            }
            // One canonical association per person is sufficient for attendance.
            if !updated.speakers.contains(where: { $0.attendancePersonID == example.personID }) {
                updated.speakers.append(speaker)
            }
        }
        let priorPeople = Set(meeting.speakers.compactMap(\.attendancePersonID))
        updated.personIDs.removeAll { priorPeople.contains($0) }
        updated.replaceSpeakers(updated.speakers)
        // Folder metadata stores associations in canonical order. Projection
        // must use the same order so a disk reload cannot trigger another save.
        updated.personIDs = MeetingListEntry(updated).personIDs
        return updated
    }

    private static func applySpeakerAssociations(
        to meeting: inout Meeting, evidence: [VoiceExample], deletedPeople: Set<UUID>, policy: VoiceMatchingPolicy,
        turnSpeakers: [UUID: UUID]
    ) {
        var scoped: [UUID: [VoiceExample]] = [:]
        for example in evidence {
            guard !example.excluded, example.attributionTurn == nil, let range = example.range else { continue }
            let speakerID: UUID?
            if example.origin == .discovery, example.detectedSpeakerConfiguration != .community { continue }
            if meeting.speakers.contains(where: { $0.id == example.speakerID && $0.canAssignPerson }) {
                speakerID = example.speakerID
            }
            else if example.origin == .discovery, example.detectedSpeakerConfiguration == .community,
                let spans = example.detectedSpeakerSpans, !spans.isEmpty, spans.allSatisfy(\.isValid)
            {
                // Discovery-local IDs are distinct from transcript speaker IDs.
                // Only map retained full support to one existing detected voice.
                // Source placeholders and ambiguous overlaps remain unchanged.
                let overlapping = meeting.transcript.filter { row in
                    guard row.associationUncertain != true, let id = row.speakerID,
                        let speaker = meeting.speakers.first(where: { $0.id == id }), speaker.canAssignPerson,
                        audioFile(for: row, speaker: speaker, meeting: meeting) == range.audioFile
                    else { return false }
                    return spans.contains { $0.start < row.end && row.start < $0.end }
                }
                let candidates = Set(overlapping.compactMap(\.speakerID))
                let candidateRows = meeting.transcript.filter { row in
                    row.associationUncertain != true && row.speakerID.map(candidates.contains) == true
                }
                let fullySupported =
                    !overlapping.isEmpty
                    && candidateRows.allSatisfy { row in
                        guard let speaker = meeting.speakers.first(where: { $0.id == row.speakerID }),
                            audioFile(for: row, speaker: speaker, meeting: meeting) == range.audioFile
                        else { return false }
                        return spans.contains { $0.start <= row.start && row.end <= $0.end }
                    }
                speakerID = fullySupported && candidates.count == 1 ? candidates.first : nil
            }
            else {
                speakerID = nil
            }
            if let speakerID { scoped[speakerID, default: []].append(example) }
        }
        for index in meeting.speakers.indices {
            let speaker = meeting.speakers[index]
            guard speaker.canAssignPerson, speaker.manuallyAssigned != true, let values = scoped[speaker.id] else {
                continue
            }
            let hasIndependentTurns =
                speaker.independentTurnAttribution == true
                || evidence.contains {
                    turnSpeakers[$0.id] == speaker.id
                }
            let confirmed =
                hasIndependentTurns
                ? []
                : values.filter {
                    !$0.manuallyCleared && $0.review == .confirmed && $0.personID != nil
                }
            let machine = values.filter {
                guard !hasIndependentTurns, !$0.manuallyCleared,
                    let association = $0.transcriptAssociation
                else { return false }
                return association.isValid && association.policy.normalized == policy.normalized
                    && !$0.rejectedPersonIDs.contains(association.personID)
            }
            let applicable = confirmed.isEmpty ? machine : confirmed
            let people = Set(applicable.compactMap { $0.personID ?? $0.transcriptAssociation?.personID })
            guard people.count == 1, let personID = people.first, !deletedPeople.contains(personID),
                !values.contains(where: { $0.manuallyCleared || $0.rejectedPersonIDs.contains(personID) }),
                let anchor = applicable.min(by: { left, right in
                    let leftTentative = left.transcriptAssociation?.tier == .tentative
                    let rightTentative = right.transcriptAssociation?.tier == .tentative
                    if leftTentative != rightTentative { return leftTentative }
                    let leftScore = left.transcriptAssociation?.score ?? 1
                    let rightScore = right.transcriptAssociation?.score ?? 1
                    return leftScore == rightScore ? left.id.uuidString < right.id.uuidString : leftScore < rightScore
                })
            else { continue }
            meeting.speakers[index].voiceReviewOrigin = .init(
                speakerID: speaker.id, personID: speaker.personID, manuallyAssigned: speaker.manuallyAssigned,
                confidence: speaker.confidence, manualReviewThrough: speaker.manualReviewThrough,
                transcriptAssociationTier: confirmed.isEmpty ? anchor.transcriptAssociation?.tier : nil)
            meeting.speakers[index].voiceReviewExampleID = anchor.id
            meeting.speakers[index].personID = personID
            meeting.speakers[index].manuallyAssigned = false
            meeting.speakers[index].confidence = confirmed.isEmpty ? anchor.transcriptAssociation?.score : nil
        }
    }

    private static func turnSpeakerScopes(_ evidence: [VoiceExample], meeting: Meeting) -> [UUID: UUID] {
        var scopes: [UUID: UUID] = [:]
        let speakers = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0) })
        for example in evidence {
            guard !example.excluded, let turn = example.attributionTurn, turn.isValid,
                let range = example.range
            else { continue }
            if speakers[example.speakerID]?.canAssignPerson == true {
                scopes[example.id] = example.speakerID
                continue
            }
            guard example.origin == .discovery, example.detectedSpeakerConfiguration == .community else { continue }
            // Discovery IDs are local to their scan. Place the independently
            // measured turn only when current, supported rows identify one voice.
            let candidates = Set(
                meeting.transcript.compactMap { row -> UUID? in
                    guard row.associationUncertain != true, row.sourcePlaceholder != true,
                        turn.start < row.end, row.start < turn.end,
                        let id = row.speakerID, let speaker = speakers[id], speaker.canAssignPerson,
                        audioFile(for: row, speaker: speaker, meeting: meeting) == range.audioFile
                    else { return nil }
                    return id
                })
            if candidates.count == 1 { scopes[example.id] = candidates.first }
        }
        return scopes
    }

    private static func audioFile(for row: TranscriptSegment, speaker: MeetingSpeaker, meeting: Meeting) -> String? {
        if let source = row.source {
            let candidates = meeting.audioFiles.filter {
                LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0)) == source.rawValue
            }
            return candidates.count == 1 ? candidates.first : nil
        }
        if speaker.track.hasPrefix("track"), let track = Int(speaker.track.dropFirst(5)),
            meeting.audioFiles.indices.contains(track)
        {
            return meeting.audioFiles[track]
        }
        if meeting.audioFiles.count == 1 { return meeting.audioFiles.first }
        let candidates = meeting.audioFiles.filter {
            let source = LocalDiarizationInputPolicy.sourceName(for: URL(fileURLWithPath: $0))
            return source == speaker.track || (source == "microphone" && speaker.track == "mic")
                || (source == "system" && speaker.track == "system_mix")
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    static func currentEvidence(_ examples: [VoiceExample], directory: URL) -> [VoiceExample] {
        guard let first = examples.first,
            let folder = try? MeetingFolderLocation.resolve(id: first.meetingID, directory: directory)
        else { return [] }
        var revisions: [String: String] = [:]
        var checked = Set<String>()
        return examples.filter { example in
            guard let range = example.range, let revision = example.audioRevision else { return false }
            if checked.insert(range.audioFile).inserted {
                revisions[range.audioFile] = VoiceLibraryStore.revision(
                    url: folder.appendingPathComponent(range.audioFile))
            }
            return revisions[range.audioFile] == revision
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
