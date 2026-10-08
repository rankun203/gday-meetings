import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct VoiceLegacyResolutionTests {
    let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2, normalization: "unitL2")

    private func seededLegacyLibrary(directory: URL, person: Person) -> VoiceLibraryStore {
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let samples = person.voiceSamples.map { sample in
            VoiceExample(
                meetingID: sample.meetingID, speakerID: sample.speakerID, source: "unknown",
                suggestedPersonID: person.id, review: .suggested,
                embeddings: [sample.resolvedVoiceEmbedding], origin: .legacyProfile)
        }
        #expect(library.upsert(samples))
        return library
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-voice-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(root: URL, track: String = "system") throws -> (Meeting, Person, URL) {
        var meeting = Meeting()
        meeting.audioFiles = ["microphone.wav", "system.wav"]
        let speaker = MeetingSpeaker(
            label: "speaker_01", track: track, providerName: "Synthetic", voiceScope: "synthetic:legacy",
            embedding: [1, 0])
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 5, end: 9, speaker: speaker.label, text: "Synthetic speech.", speakerID: speaker.id)
        ]
        try MeetingFolderStorage.write(meeting, directory: root)
        let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: root)
        for file in meeting.audioFiles {
            try Data("Synthetic source bytes.".utf8).write(to: folder.appendingPathComponent(file))
        }
        let person = Person(
            name: "Alex",
            voiceSamples: [
                .init(meetingID: meeting.id, speakerID: speaker.id, scope: "synthetic:legacy", embedding: [1, 0])
            ])
        return (meeting, person, folder)
    }

    @Test func resolvingAudioPreservesStoredRepresentations() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, person, folder) = try fixture(root: directory)
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        let preparation = VoiceLibraryPreparation(library: library)
        let recovered = try #require(await preparation.findPlayableExample(exampleID: old.id, directory: folder))
        #expect(recovered.id == old.id && recovered.groupID == old.groupID)
        #expect(recovered.audioFile == "system.wav" && recovered.start == 5 && recovered.end == 9)
        #expect(recovered.firstPassage?.start == 5)
        #expect(recovered.suggestedPersonID == person.id)
        #expect(recovered.embeddings.count == 1)
        #expect(library.audioIsCurrent(recovered))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.isEmpty)
        #expect(try MeetingFolderStorage.read(id: meeting.id, directory: directory).transcript == meeting.transcript)
        #expect(library.ingest(meeting: meeting, directory: folder))
        #expect(library.examples.count == 1)
    }

    @Test func confirmationUsesAllCompatibleRepresentationsWithoutSourceAudio() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = Person(name: "Alex")
        let vector = TypedVoiceEmbedding(type: type, values: [1, 0])
        let sample = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "unknown",
            embeddings: [vector])
        #expect(library.upsert([sample]))
        #expect(library.confirm(ids: [sample.id], personID: person.id))
        let profiles = (try await library.matchingPeople(from: [person]))
        #expect(SpeakerRecognition.match(embedding: vector, people: profiles)?.personID == person.id)
        var incompatible = vector
        incompatible.type.revision = "different-model-revision"
        #expect(SpeakerRecognition.match(embedding: incompatible, people: profiles) == nil)
        #expect(library.reject(ids: [sample.id], personID: person.id))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.isEmpty)
    }

    @Test func legacyDocumentRequiresExplicitMigrationAndRemainsUnchanged() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var document = VoiceLibraryDocument()
        document.examples = [VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "unknown")]
        let url = directory.appendingPathComponent("voice-library.json")
        let data = try JSONEncoder().encode(document)
        try data.write(to: url)
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.examples.isEmpty && library.errorMessage != nil)
        #expect(!library.upsert(document.examples))
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func resolvingAudioPreservesRejectedAndClearedDecisions() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, person, folder) = try fixture(root: directory)
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        #expect(library.reject(ids: [old.id], personID: person.id))
        #expect(library.clear(ids: [old.id]))
        let resolved = try #require(
            library.resolveLegacyExample(exampleID: old.id, meeting: meeting, directory: folder))
        #expect(resolved.manuallyCleared && resolved.rejectedPersonIDs == [person.id])
        #expect(library.addRepresentation(exampleID: old.id, embedding: .init(type: type, values: [1, 0])))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.isEmpty)
        #expect(library.confirm(ids: [old.id], personID: person.id))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 1)
    }

    @Test func confirmedSpeakerCanProjectOntoItsLocatedAudio() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, person, folder) = try fixture(root: directory)
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        #expect(library.confirm(ids: [old.id], personID: person.id))
        #expect(library.resolveLegacyExample(exampleID: old.id, meeting: meeting, directory: folder) != nil)
        #expect(library.applyingDecisions(to: meeting).speakers.contains { $0.personID == person.id })
        #expect(library.confirm(ids: [old.id], personID: person.id))
        #expect(library.applyingDecisions(to: meeting).speakers.contains { $0.personID == person.id })
    }

    @Test func ambiguousSourceAndOverlappingSpeechNeverInventAnExcerpt() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (ambiguous, person, folder) = try fixture(root: directory, track: "unknown")
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        let unresolved = try #require(
            library.resolveLegacyExample(exampleID: old.id, meeting: ambiguous, directory: folder))
        #expect(!unresolved.isPlayable && unresolved.sourceResolutionIssue != nil)
        var overlapping = ambiguous
        overlapping.speakers[0].track = "system"
        let competitor = MeetingSpeaker(label: "speaker_02", track: "system", providerName: "Synthetic")
        overlapping.speakers.append(competitor)
        overlapping.transcript.append(
            .init(
                start: 6, end: 8, speaker: competitor.label, text: "Other synthetic speech.", speakerID: competitor.id))
        let fallback = try #require(
            library.resolveLegacyExample(exampleID: old.id, meeting: overlapping, directory: folder))
        #expect(!fallback.isPlayable && fallback.firstPassage?.start == 5)
        #expect(fallback.embeddings.count == 1)
    }

    @Test func equalVectorValuesFromDifferentSpacesDoNotRecoverSpeakerIdentity() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, _, _) = try fixture(root: directory)
        meeting.speakers[0].voiceEmbedding = .init(type: type, values: [1, 0])
        var other = type
        other.revision = "v2"
        let example = VoiceExample(
            meetingID: meeting.id, speakerID: UUID(), source: "unknown",
            embeddings: [.init(type: other, values: [1, 0])])
        #expect(VoiceExampleResolution.resolve(example, meeting: meeting) == nil)
    }

    @Test func deletingPersonClearsHistoricalAssociation() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, person, _) = try fixture(root: directory)
        let library = seededLegacyLibrary(directory: directory, person: person)
        #expect(library.removePerson(id: person.id))
        #expect(library.examples.first?.suggestedPersonID == nil)
        #expect(library.examples(for: person.id).isEmpty)
    }

    @Test func rejectedRepresentationVetoesSuggestionsAcrossStorageFields() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, originalPerson, folder) = try fixture(root: directory)
        var person = originalPerson
        let vector = TypedVoiceEmbedding(type: type, values: [1, 0])
        person.voiceSamples[0] = .init(meetingID: meeting.id, speakerID: meeting.speakers[0].id, voiceEmbedding: vector)
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        #expect(library.reject(ids: [old.id], personID: person.id))
        #expect(library.resolveLegacyExample(exampleID: old.id, meeting: meeting, directory: folder) != nil)
        let candidate = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system", embeddings: [vector])
        #expect(library.upsert([candidate]))
        #expect(library.suggest(exampleID: candidate.id, personID: person.id))
        #expect(library.examples.first(where: { $0.id == candidate.id })?.suggestedPersonID == nil)
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.isEmpty)
    }

    @Test func projectedSpeakerOriginsRecoverOnlyAnUnambiguousAudioSource() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, person, folder) = try fixture(root: directory)
        let original = meeting.speakers[0]
        meeting.speakers[0].id = UUID()
        meeting.speakers[0].voiceReviewOrigin = .init(speakerID: original.id)
        meeting.transcript[0].speakerID = meeting.speakers[0].id
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        let recovered = try #require(
            library.resolveLegacyExample(exampleID: old.id, meeting: meeting, directory: folder))
        #expect(recovered.speakerID == original.id && recovered.audioFile == "system.wav")
        #expect(recovered.start == 5 && recovered.embeddings.count == 1)
        var conflicting = meeting.speakers[0]
        conflicting.id = UUID()
        conflicting.track = "microphone"
        meeting.speakers.append(conflicting)
        #expect(VoiceExampleResolution.resolve(old, meeting: meeting) == nil)
    }

    @Test func undoRestoresConfirmationAfterAudioRecovery() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, person, folder) = try fixture(root: directory)
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        #expect(library.confirm(ids: [old.id], personID: person.id))
        #expect(library.reject(ids: [old.id], personID: person.id))
        #expect(library.resolveLegacyExample(exampleID: old.id, meeting: meeting, directory: folder) != nil)
        #expect(library.addRepresentation(exampleID: old.id, embedding: .init(type: type, values: [1, 0])))
        #expect(library.undo())
        #expect(library.examples.first?.review == .confirmed)
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 1)
        #expect(library.applyingDecisions(to: meeting).speakers.contains { $0.personID == person.id })
        #expect(library.confirm(ids: [old.id], personID: person.id))
        #expect(library.reject(ids: [old.id], personID: person.id))
        #expect(library.undo())
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 1)
    }

    @Test func missingMicrophoneCannotFallBackToContradictorySystemAudio() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, person, folder) = try fixture(root: directory, track: "microphone")
        meeting.audioFiles = ["system.wav"]
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        let unresolved = try #require(
            library.resolveLegacyExample(exampleID: old.id, meeting: meeting, directory: folder))
        #expect(unresolved.range == nil && unresolved.firstPassage == nil)
        #expect(unresolved.sourceResolutionIssue != nil)
        #expect(VoiceExampleResolution.sourceFile(for: meeting.speakers[0], meeting: meeting) == nil)
        meeting.audioFiles = ["recording.wav"]
        #expect(VoiceExampleResolution.sourceFile(for: meeting.speakers[0], meeting: meeting) == "recording.wav")
    }
}
