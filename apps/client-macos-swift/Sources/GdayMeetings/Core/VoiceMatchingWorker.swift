import Foundation

/// Serializes profile work without sharing the main actor's persistence backend.
actor VoiceMatchingWorker {
    struct Input: Sendable {
        var directory: URL
        var persistence: VoiceLibraryPersistence.Snapshot
        var examples: [VoiceExample]
        var people: [Person]
        var deletedPeople: [UUID]
        var includeSuggestions: Bool
    }
    struct Suggestion: Sendable {
        var exampleID: UUID
        var personID: UUID?
    }
    struct Output: Sendable {
        var profiles: [Person]
        var suggestions: [Suggestion]
    }

    func run(
        _ input: Input, beforeRead: (@Sendable () throws -> Void)?,
        beforeValidation: (@Sendable () throws -> Void)?
    ) throws -> Output {
        try Task.checkCancellation()
        try beforeRead?()
        try Task.checkCancellation()
        let backend = try VoiceLibraryPersistence(directory: input.directory, writable: false)
        backend.adopt(input.persistence)
        let conflicts = VoiceReviewConflicts.confirmedExampleIDs(in: input.examples)
        let personIDs = Set(input.people.map(\.id)).subtracting(input.deletedPeople)
        var hydrated: [UUID: VoiceExample] = [:]
        for var example in input.examples {
            try Task.checkCancellation()
            let confirmed =
                example.review == .confirmed && !example.excluded
                && example.personID.map(personIDs.contains) == true && !conflicts.contains(example.id)
            let neededForSuggestion =
                input.includeSuggestions
                && (!example.isReviewed || !example.rejectedPersonIDs.isEmpty)
            guard confirmed || neededForSuggestion else { continue }
            example.embeddings = try backend.loadRepresentations(exampleID: example.id)?.embeddings ?? []
            hydrated[example.id] = example
        }
        let byPerson = Dictionary(
            grouping: input.examples.filter {
                $0.review == .confirmed && !$0.excluded && !conflicts.contains($0.id) && $0.personID != nil
            }, by: { $0.personID! })
        var profiles: [Person] = []
        for var person in input.people {
            try Task.checkCancellation()
            let confirmed = (byPerson[person.id] ?? []).compactMap { hydrated[$0.id] }
            let evidence = confirmed.flatMap { example in
                example.embeddings.filter(\.isValid).map {
                    SpeakerEvidenceSample(
                        id: example.id.uuidString, source: example.source,
                        localSpeakerID: example.groupID.uuidString,
                        start: example.start ?? 0, end: example.end ?? 0, embedding: $0)
                }
            }
            let selected = try Dictionary(grouping: evidence, by: \.model).values.flatMap {
                try VoiceProfileSelection.selectCancellable($0, limit: 12, cancellationCheck: Task.checkCancellation)
            }.sorted { $0.id < $1.id }
            let byID = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id.uuidString, $0) })
            person.voiceSamples = selected.compactMap { sample in
                guard let example = byID[sample.id] else { return nil }
                return PersonVoiceSample(
                    meetingID: example.meetingID, speakerID: example.id, voiceEmbedding: sample.embedding)
            }
            profiles.append(person)
        }
        let rejected = hydrated.values.filter { !$0.rejectedPersonIDs.isEmpty }
        var suggestions: [Suggestion] = []
        if input.includeSuggestions {
            for metadata in input.examples where !metadata.isReviewed {
                try Task.checkCancellation()
                guard let example = hydrated[metadata.id] else { continue }
                let matches = Set(
                    example.embeddings.compactMap {
                        SpeakerRecognition.match(embedding: $0, people: profiles)?.personID
                    })
                var person = matches.count == 1 ? matches.first : nil
                if let candidate = person {
                    for rejection in rejected where rejection.rejectedPersonIDs.contains(candidate) {
                        try Task.checkCancellation()
                        if example.embeddings.contains(where: { embedding in
                            rejection.embeddings.contains {
                                $0.type == embedding.type && $0.isValid && embedding.isValid
                                    && (SpeakerRecognition.similarity($0.values, embedding.values) ?? -1)
                                        >= SpeakerRecognition.threshold
                            }
                        }) {
                            person = nil
                            break
                        }
                    }
                    if input.deletedPeople.contains(candidate) || example.rejectedPersonIDs.contains(candidate) {
                        person = nil
                    }
                }
                suggestions.append(.init(exampleID: example.id, personID: person))
            }
        }
        try beforeValidation?()
        // Each validation acquires a short lock. Selection never blocks a review writer.
        for id in hydrated.keys {
            try Task.checkCancellation()
            try backend.validateRepresentationRevision(exampleID: id)
        }
        try backend.validateMatchingMetadataRevisions()
        try backend.validateCurrentRevision()
        try Task.checkCancellation()
        return Output(profiles: profiles, suggestions: suggestions)
    }
}
