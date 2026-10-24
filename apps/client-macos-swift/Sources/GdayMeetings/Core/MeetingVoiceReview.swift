import Foundation

/// Captures the user's selection at click time, before any queued capture write.
enum VoiceReviewAction: Sendable {
    case confirm(ids: Set<UUID>, personID: UUID)
    case reject(ids: Set<UUID>, personID: UUID, restoreExcluded: Bool = false)
    case clear(ids: Set<UUID>)
    case exclude(ids: Set<UUID>, excluded: Bool)
    case split(ids: Set<UUID>)
    case merge(ids: Set<UUID>)
    case undo

    var exampleIDs: Set<UUID>? {
        switch self {
        case .confirm(let ids, _), .reject(let ids, _, _), .clear(let ids),
            .exclude(let ids, _), .split(let ids), .merge(let ids):
            return ids
        case .undo: return nil
        }
    }
}

struct VoiceReviewReceipt: Sendable {
    var personID: UUID?
    var undoID: UUID?
}

extension MeetingStore {
    @discardableResult
    func reviewVoiceExamples(
        _ action: VoiceReviewAction, expectedExamples: [VoiceExample]? = nil, expectedUndoID: UUID? = nil
    ) async -> Bool {
        await reviewVoiceExamplesResult(action, expectedExamples: expectedExamples, expectedUndoID: expectedUndoID)
            != nil
    }

    func reviewVoiceExamplesResult(
        _ action: VoiceReviewAction, expectedExamples: [VoiceExample]? = nil, expectedUndoID: UUID? = nil
    ) async -> VoiceReviewReceipt? {
        let interval = ReviewPerformance.signposter.beginInterval(
            "Commit voice review", id: ReviewPerformance.signposter.makeSignpostID())
        defer { ReviewPerformance.signposter.endInterval("Commit voice review", interval) }
        let library = voiceLibrary
        guard await library.awaitReady(), libraryWritable, voiceLibrary === library else { return nil }
        var undoMeetings = Set<UUID>()
        var receipt: VoiceReviewReceipt?
        let result = await enqueueCanonical { [self] in
            guard libraryWritable, voiceLibrary === library else { return false }
            if let ids = action.exampleIDs,
                ids.isEmpty || !ids.isSubset(of: Set(library.examples.map(\.id)))
            {
                errorMessage = "This voice example changed while saving. Select an example again."
                return false
            }
            if let expectedExamples, let ids = action.exampleIDs {
                let current = Dictionary(uniqueKeysWithValues: library.examples.map { ($0.id, $0) })
                guard Set(expectedExamples.map(\.id)) == ids,
                    expectedExamples.allSatisfy({ expected in
                        current[expected.id]?.hasSameReviewEvidence(as: expected) == true
                    })
                else {
                    errorMessage = "This sample changed during review. Close review and open it again."
                    return false
                }
            }
            if case .undo = action, let expectedUndoID, library.reviewUndoID != expectedUndoID {
                errorMessage = "Another voice change was saved. This review action can no longer be undone here."
                return false
            }
            let previousUndoID = library.reviewUndoID
            let succeeded: Bool
            switch action {
            case .confirm(let ids, let personID):
                guard people.contains(where: { $0.id == personID }) else {
                    errorMessage = "This person is no longer available. Choose another person."
                    return false
                }
                succeeded = voiceLibrary.confirm(ids: ids, personID: personID)
            case .reject(let ids, let personID, let restoreExcluded):
                succeeded = voiceLibrary.reject(ids: ids, personID: personID, restoreExcluded: restoreExcluded)
            case .clear(let ids): succeeded = voiceLibrary.clear(ids: ids)
            case .exclude(let ids, let excluded): succeeded = voiceLibrary.exclude(ids: ids, excluded: excluded)
            case .split(let ids): succeeded = voiceLibrary.split(ids: ids)
            case .merge(let ids): succeeded = voiceLibrary.merge(ids: ids)
            case .undo:
                if let created = library.reviewUndoCreatedPerson {
                    undoMeetings = Set(
                        library.examples.filter { library.reviewUndoExampleIDs.contains($0.id) }.map(\.meetingID))
                    let saved = await undoVoicePersonCreation(created, expectedUndoID: expectedUndoID)
                    if saved { receipt = .init(personID: nil, undoID: nil) }
                    return saved
                }
                succeeded = voiceLibrary.undo(expectedUndoID: expectedUndoID)
            }
            if !succeeded { errorMessage = voiceLibrary.errorMessage ?? "Couldn’t save the voice review. Try again." }
            if succeeded {
                let undoID: UUID?
                if case .undo = action {
                    undoID = nil
                }
                else {
                    undoID = library.reviewUndoID == previousUndoID ? nil : library.reviewUndoID
                }
                receipt = .init(personID: nil, undoID: undoID)
            }
            return succeeded
        }
        if result && !undoMeetings.isEmpty {
            scheduleVoiceAssignmentRefresh(meetingIDs: undoMeetings)
        }
        return result ? receipt : nil
    }

    /// Creates the contact and saves every selected association in the same
    /// existing canonical transaction. A failure publishes neither half.
    @discardableResult
    func nameVoiceGroup(
        exampleIDs: Set<UUID>, confirmedExampleID: UUID?, personID: UUID?, newPersonName: String?,
        expectedExamples: [VoiceExample]
    ) async -> UUID? {
        await nameVoiceGroupResult(
            exampleIDs: exampleIDs, confirmedExampleID: confirmedExampleID, personID: personID,
            newPersonName: newPersonName, expectedExamples: expectedExamples)?.personID
    }

    func nameVoiceGroupResult(
        exampleIDs: Set<UUID>, confirmedExampleID: UUID?, personID: UUID?, newPersonName: String?,
        expectedExamples: [VoiceExample]
    ) async -> VoiceReviewReceipt? {
        let interval = ReviewPerformance.signposter.beginInterval(
            "Commit voice review", id: ReviewPerformance.signposter.makeSignpostID())
        defer { ReviewPerformance.signposter.endInterval("Commit voice review", interval) }
        let library = voiceLibrary
        guard await library.awaitReady(), libraryWritable, voiceLibrary === library else { return nil }
        let cleanName = newPersonName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (personID != nil) != (cleanName?.isEmpty == false), !exampleIDs.isEmpty else {
            errorMessage = "Choose a person or enter a new name."
            return nil
        }
        let created = cleanName.flatMap { $0.isEmpty ? nil : Person(name: $0) }
        let chosenID = personID ?? created!.id
        var receipt: VoiceReviewReceipt?
        let saved = await enqueueCanonical { [self] in
            guard libraryWritable, voiceLibrary === library,
                created != nil || people.contains(where: { $0.id == chosenID })
            else { return false }
            let current = Dictionary(uniqueKeysWithValues: library.examples.map { ($0.id, $0) })
            guard Set(expectedExamples.map(\.id)) == exampleIDs,
                expectedExamples.allSatisfy({ current[$0.id]?.hasSameReviewEvidence(as: $0) == true })
            else {
                errorMessage = "These samples changed during identification. Refresh the list and try again."
                return false
            }
            guard
                library.nameGroup(
                    ids: exampleIDs, confirmedExampleID: confirmedExampleID, personID: chosenID,
                    createdPerson: created, staged: true)
            else {
                errorMessage =
                    library.errorMessage ?? "These samples can’t be assigned. Refresh the list and try again."
                return false
            }
            if let created { people.append(created) }
            let committed = await performCanonicalSave(commitVoice: true)
            if committed {
                receipt = .init(personID: chosenID, undoID: library.reviewUndoID)
            }
            else if libraryWritable, let created, people.first(where: { $0.id == created.id }) == created {
                // The generic rollback preserves unrelated concurrent edits.
                // Remove only this command's unchanged, unpublished contact.
                people.removeAll { $0.id == created.id }
            }
            return committed
        }
        if saved {
            // The canonical transaction above is the acknowledgement boundary.
            // Store-owned projection and matching continue after the dialog closes;
            // subsequent corrections and Undo retain canonical queue ordering.
            scheduleVoiceAssignmentRefresh(meetingIDs: Set(expectedExamples.map(\.meetingID)))
        }
        return saved ? receipt : nil
    }

    private func undoVoicePersonCreation(_ created: Person, expectedUndoID: UUID?) async -> Bool {
        let library = voiceLibrary
        let ids = library.reviewUndoExampleIDs
        let affectedMeetings = Set(library.examples.filter { ids.contains($0.id) }.map(\.meetingID))
        let machineMeetings = Set(
            library.examples.filter {
                $0.transcriptAssociation?.personID == created.id
            }.map(\.meetingID))
        let allowedMeetings = affectedMeetings.union(machineMeetings)
        guard people.first(where: { $0.id == created.id }) == created,
            !library.examples.contains(where: {
                !ids.contains($0.id) && ($0.personID == created.id || $0.namedPersonID == created.id)
            }), contextualChats[Self.contextChatKey(personID: created.id)]?.isEmpty != false
        else {
            errorMessage = "This person changed after naming. Keep the person and edit the samples individually."
            return false
        }
        do {
            let related = try libraryIndex?.page(limit: allowedMeetings.count + 1, personID: created.id) ?? []
            guard Set(related.map(\.id)).isSubset(of: allowedMeetings) else {
                errorMessage = "This person is used in another recording. Edit the samples individually."
                return false
            }
            let root = dataDirectory
            let reader = meetingLoadReader
            let meetingSnapshot = meetings
            let loaded = Dictionary(uniqueKeysWithValues: meetingSnapshot.map { ($0.id, $0) })
            let relatedIDs = Set(related.map(\.id)).union(
                meetingSnapshot.filter {
                    $0.personIDs.contains(created.id) || $0.speakers.contains { $0.personID == created.id }
                }.map(\.id))
            guard relatedIDs.isSubset(of: allowedMeetings) else {
                errorMessage = "This person is used in another recording. Edit the samples individually."
                return false
            }
            let relatedMeetings = try await Task.detached(priority: .utility) {
                try relatedIDs.map { try loaded[$0] ?? reader($0, root) }
            }.value
            let latestRelated = try libraryIndex?.page(limit: allowedMeetings.count + 1, personID: created.id) ?? []
            // Background projection may load unrelated recordings while this
            // check yields. Only changes affecting this person's use invalidate Undo.
            let checked = Dictionary(uniqueKeysWithValues: relatedMeetings.map { ($0.id, $0) })
            let currentRelevant = meetings.filter {
                relatedIDs.contains($0.id) || $0.personIDs.contains(created.id)
                    || $0.speakers.contains { $0.personID == created.id }
                    || $0.transcript.contains { $0.personID == created.id }
            }
            guard currentRelevant.allSatisfy({ checked[$0.id] == $0 }),
                Set(latestRelated.map(\.id)) == Set(related.map(\.id)),
                relatedMeetings.allSatisfy({ meeting in
                    let assigned = meeting.speakers.filter { $0.personID == created.id }
                    return !assigned.isEmpty
                        && assigned.allSatisfy {
                            $0.voiceReviewExampleID.map(ids.contains) == true
                                || ($0.voiceReviewOrigin?.transcriptAssociationTier != nil
                                    && $0.manuallyAssigned != true
                                    && machineMeetings.contains(meeting.id))
                        } && !meeting.transcript.contains { $0.personID == created.id }
                }), library.reviewUndoID == expectedUndoID || expectedUndoID == nil,
                people.first(where: { $0.id == created.id }) == created
            else {
                errorMessage = "This person has another assignment. Edit the samples individually."
                return false
            }
        }
        catch {
            errorMessage = "Couldn’t check this person’s recordings. Try Undo again."
            return false
        }
        guard library.undo(expectedUndoID: expectedUndoID, staged: true) else { return false }
        let position = people.firstIndex { $0.id == created.id } ?? people.count
        people.removeAll { $0.id == created.id }
        let committed = await performCanonicalSave(commitVoice: true)
        if !committed, libraryWritable, !people.contains(where: { $0.id == created.id }) {
            people.insert(created, at: min(position, people.count))
        }
        return committed
    }
}
