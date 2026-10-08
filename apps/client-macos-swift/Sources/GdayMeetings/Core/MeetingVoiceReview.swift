import Foundation

/// Captures the user's selection at click time, before any queued capture write.
enum VoiceReviewAction: Sendable {
    case confirm(ids: Set<UUID>, personID: UUID)
    case reject(ids: Set<UUID>, personID: UUID)
    case clear(ids: Set<UUID>)
    case exclude(ids: Set<UUID>, excluded: Bool)
    case split(ids: Set<UUID>)
    case merge(ids: Set<UUID>)
    case undo

    var exampleIDs: Set<UUID>? {
        switch self {
        case .confirm(let ids, _), .reject(let ids, _), .clear(let ids),
            .exclude(let ids, _), .split(let ids), .merge(let ids):
            return ids
        case .undo: return nil
        }
    }
}

extension MeetingStore {
    @discardableResult
    func reviewVoiceExamples(_ action: VoiceReviewAction) async -> Bool {
        let library = voiceLibrary
        guard await library.awaitReady(), libraryWritable, voiceLibrary === library else { return false }
        return await enqueueCanonical { [self] in
            guard libraryWritable, voiceLibrary === library else { return false }
            if let ids = action.exampleIDs,
                ids.isEmpty || !ids.isSubset(of: Set(library.examples.map(\.id)))
            {
                errorMessage = "This voice example changed while saving. Select an example again."
                return false
            }
            let succeeded: Bool
            switch action {
            case .confirm(let ids, let personID):
                guard people.contains(where: { $0.id == personID }) else {
                    errorMessage = "This person is no longer available. Choose another person."
                    return false
                }
                succeeded = voiceLibrary.confirm(ids: ids, personID: personID)
            case .reject(let ids, let personID):
                succeeded = voiceLibrary.reject(ids: ids, personID: personID)
            case .clear(let ids): succeeded = voiceLibrary.clear(ids: ids)
            case .exclude(let ids, let excluded): succeeded = voiceLibrary.exclude(ids: ids, excluded: excluded)
            case .split(let ids): succeeded = voiceLibrary.split(ids: ids)
            case .merge(let ids): succeeded = voiceLibrary.merge(ids: ids)
            case .undo: succeeded = voiceLibrary.undo()
            }
            if !succeeded { errorMessage = voiceLibrary.errorMessage ?? "Couldn’t save the voice review. Try again." }
            return succeeded
        }
    }
}
