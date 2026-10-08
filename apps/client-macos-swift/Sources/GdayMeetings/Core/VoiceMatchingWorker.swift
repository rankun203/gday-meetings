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

    private struct ProfileKey: Equatable, Sendable {
        var directory: URL
        var person: Person
        var examples: [VoiceExample]
        var dependencies: [String: String]
    }
    private struct CachedProfile: Sendable {
        var key: ProfileKey
        var task: Task<Person, Error>
    }
    private var profileTasks: [UUID: CachedProfile] = [:]
    private(set) var profileBuildCount = 0
    private let beforeProfileRead: (@Sendable () throws -> Void)?
    init(beforeProfileRead: (@Sendable () throws -> Void)? = nil) { self.beforeProfileRead = beforeProfileRead }
    deinit { for cached in profileTasks.values { cached.task.cancel() } }

    private static func buildProfile(_ key: ProfileKey) throws -> Person {
        let backend = try VoiceLibraryPersistence(directory: key.directory, writable: false)
        var confirmed: [VoiceExample] = []
        for var example in key.examples {
            try Task.checkCancellation()
            example.embeddings =
                try backend.loadProfileRepresentations(exampleID: example.id, dependencies: key.dependencies)?
                .embeddings ?? []
            confirmed.append(example)
        }
        let evidence = confirmed.flatMap { example in
            example.embeddings.filter(\.isValid).map {
                SpeakerEvidenceSample(
                    id: example.id.uuidString, source: example.source,
                    localSpeakerID: example.groupID.uuidString, start: example.start ?? 0,
                    end: example.end ?? 0, embedding: $0)
            }
        }
        let selected = try Dictionary(grouping: evidence, by: \.model).values.flatMap {
            try VoiceProfileSelection.selectCancellable($0, limit: 12, cancellationCheck: Task.checkCancellation)
        }.sorted { $0.id < $1.id }
        let byID = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.id.uuidString, $0) })
        var person = key.person
        person.voiceSamples = selected.compactMap { sample in
            guard let example = byID[sample.id] else { return nil }
            return PersonVoiceSample(
                meetingID: example.meetingID, speakerID: example.id, voiceEmbedding: sample.embedding)
        }
        try backend.validateProfileDependencies(key.dependencies)
        return person
    }

    func run(
        _ input: Input, beforeRead: (@Sendable () throws -> Void)?,
        beforeValidation: (@Sendable () throws -> Void)?
    ) async throws -> Output {
        try Task.checkCancellation()
        try beforeRead?()
        try Task.checkCancellation()
        let backend = try VoiceLibraryPersistence(directory: input.directory, writable: false)
        backend.adopt(input.persistence)
        let conflicts = VoiceReviewConflicts.confirmedExampleIDs(in: input.examples)
        let personIDs = Set(input.people.map(\.id)).subtracting(input.deletedPeople)
        let eligible = input.examples.filter {
            $0.review == .confirmed && !$0.excluded && !conflicts.contains($0.id)
                && $0.personID.map(personIDs.contains) == true
        }
        let dependencies = try backend.profileDependencyRevisions(exampleIDs: eligible.map(\.id))
        let byPerson = Dictionary(grouping: eligible, by: { $0.personID! })
        for id in Array(profileTasks.keys) where !personIDs.contains(id) {
            profileTasks.removeValue(forKey: id)?.task.cancel()
        }
        var currentTasks: [CachedProfile] = []
        for person in input.people where personIDs.contains(person.id) {
            let confirmed = (byPerson[person.id] ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
            var selectedDependencies: [String: String] = [:]
            for example in confirmed {
                for path in ["examples/\(example.id.uuidString).json", "representations/\(example.id.uuidString).json"]
                {
                    selectedDependencies[path] = dependencies[path]
                }
            }
            let key = ProfileKey(
                directory: input.directory, person: person, examples: confirmed, dependencies: selectedDependencies)
            if profileTasks[person.id]?.key != key {
                profileTasks.removeValue(forKey: person.id)?.task.cancel()
                profileBuildCount += 1
                // A live candidate update cancels its waiter, not reviewed work.
                // A changed reviewed dependency replaces and cancels this task.
                let beforeProfileRead = self.beforeProfileRead
                profileTasks[person.id] = CachedProfile(
                    key: key,
                    task: Task.detached(priority: .utility) {
                        try beforeProfileRead?()
                        return try Self.buildProfile(key)
                    })
            }
            currentTasks.append(profileTasks[person.id]!)
        }
        var profiles: [Person] = []
        for cached in currentTasks {
            do { profiles.append(try await cached.task.value) }
            catch {
                if profileTasks[cached.key.person.id]?.key == cached.key {
                    profileTasks.removeValue(forKey: cached.key.person.id)
                }
                throw error
            }
            try Task.checkCancellation()
        }
        // Cached profiles are usable only while their exact reviewed records stay
        // unchanged, including edits performed outside this process.
        try backend.validateProfileDependencies(dependencies)
        var hydrated: [UUID: VoiceExample] = [:]
        for var example in input.examples
        where input.includeSuggestions
            && (!example.isReviewed || !example.rejectedPersonIDs.isEmpty)
        {
            try Task.checkCancellation()
            example.embeddings = try backend.loadRepresentations(exampleID: example.id)?.embeddings ?? []
            hydrated[example.id] = example
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
        try backend.validateProfileDependencies(dependencies)
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
