import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct VoiceLibraryTests {
    let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2,
        normalization: "unitL2")

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
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func example(
        root: URL, meetingID: UUID = UUID(), speakerID: UUID = UUID(), start: Double = 0,
        end: Double = 4
    ) throws -> VoiceExample {
        let folder = try MeetingFolderLocation.newFolder(id: meetingID, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("system.wav")
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data("synthetic audio fixture".utf8).write(to: file)
        }
        return VoiceExample(
            meetingID: meetingID, speakerID: speakerID, source: "system", audioFile: "system.wav",
            audioRevision: VoiceLibraryStore.revision(url: file), start: start, end: end,
            embeddings: [.init(type: type, values: [1, 0])])
    }

    @Test func onlyReviewedPlayableExamplesEnrollAndLaterSamplesStayUnreviewed() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let person = Person(name: "Alex")
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let first = try example(root: directory)
        #expect(library.upsert([first]))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.isEmpty)
        #expect(library.confirm(ids: [first.id], personID: person.id))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 1)
        var later = try example(
            root: directory, meetingID: first.meetingID, speakerID: first.speakerID, start: 5, end: 9)
        later.suggestedPersonID = person.id
        later.review = .suggested
        #expect(library.upsert([later]))
        #expect(library.examples.count == 2)
        #expect(library.examples.filter { $0.review == .confirmed }.count == 1)
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 1)
    }

    @Test func confirmedSamplesWithoutAudioCanSeedTheirMatchingModel() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let person = Person(
            name: "Alex",
            voiceSamples: [
                .init(meetingID: UUID(), speakerID: UUID(), voiceEmbedding: .init(type: type, values: [1, 0]))
            ])
        let library = seededLegacyLibrary(directory: directory, person: person)
        let old = try #require(library.examples.first)
        #expect(old.review == .suggested && !old.isPlayable)
        #expect(old.origin == .legacyProfile && old.suggestedPersonID == person.id)
        #expect(old.suggestedPersonID == person.id && old.embeddings.isEmpty)
        #expect(library.confirm(ids: [old.id], personID: person.id))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 1)
    }

    @Test func rejectionSurvivesReopeningAndOnlySuppressesItsExactPair() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let personID = UUID()
        var rejected = try example(root: directory)
        rejected.suggestedPersonID = personID
        rejected.review = .suggested
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([rejected]))
        #expect(library.reject(ids: [rejected.id], personID: personID))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        let candidate = try example(root: directory)
        #expect(reopened.upsert([candidate]))
        #expect(reopened.suggest(exampleID: candidate.id, personID: personID))
        #expect(reopened.examples.first { $0.id == candidate.id }?.suggestedPersonID == personID)
        #expect(reopened.suggest(exampleID: rejected.id, personID: personID))
        #expect(reopened.examples.first { $0.id == rejected.id }?.suggestedPersonID == nil)
        let other = UUID()
        #expect(reopened.suggest(exampleID: rejected.id, personID: other))
        #expect(reopened.examples.first { $0.id == rejected.id }?.suggestedPersonID == other)
        #expect(reopened.examples.first { $0.id == rejected.id }?.rejectedPersonIDs == [personID])
    }

    @Test func asynchronousReviewUsesPersistedEmbeddingsAndExactPairDecisions() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = Person(name: "Alex")
        let other = Person(name: "Sam")
        let seed = try example(root: directory)
        var candidate = try example(root: directory)
        candidate.embeddings[0].values = [0.79, sqrt(1 - 0.79 * 0.79)]
        let unavailable = try example(root: directory)
        #expect(library.upsert([seed, candidate, unavailable]))
        #expect(library.confirm(ids: [seed.id], personID: person.id))
        let folder = try MeetingFolderLocation.resolve(id: unavailable.meetingID, directory: directory)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("system.wav"))
        #expect(
            Set(try await library.matchingPeople(from: [person]).flatMap(\.voiceSamples).map(\.speakerID)) == [seed.id])
        #expect(try await library.reviewCandidates(for: person.id).map(\.id) == [candidate.id])
        #expect(library.reject(ids: [candidate.id], personID: person.id))
        #expect(try await library.reviewCandidates(for: person.id).isEmpty)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(try await reopened.reviewCandidates(for: person.id).isEmpty)
        let otherSeed = try example(root: directory)
        #expect(reopened.upsert([otherSeed]))
        #expect(reopened.confirm(ids: [otherSeed.id], personID: other.id))
        try await reopened.suggestReviewedPeopleResult(from: [person, other])
        // Equal acoustic scores stay ambiguous after a pair-specific rejection.
        // The other person remains available for explicit review below.
        #expect(reopened.examples.first { $0.id == candidate.id }?.suggestedPersonID == nil)
        #expect(reopened.examples.first { $0.id == candidate.id }?.transcriptAssociation == nil)
        #expect(reopened.examples.first { $0.id == candidate.id }?.rejectedPersonIDs == [person.id])
        #expect(try await reopened.reviewCandidates(for: other.id).map(\.id) == [candidate.id])
    }

    @Test func queuedReviewChecksCanonicalEvidenceBeforeSaving() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        store.voiceLibrary.didChange = nil
        let person = await store.addPerson(name: "Alex")
        let sample = try example(root: directory)
        #expect(store.voiceLibrary.upsert([sample]))
        #expect(store.voiceLibrary.suggest(exampleID: sample.id, personID: person))
        #expect(
            await store.reviewVoiceExamples(.confirm(ids: [sample.id], personID: person), expectedExamples: [sample]))
        #expect(
            await !store.reviewVoiceExamples(.reject(ids: [sample.id], personID: person), expectedExamples: [sample]))
        #expect(store.voiceLibrary.examples.first?.personID == person)
        #expect(store.voiceLibrary.examples.first?.rejectedPersonIDs.isEmpty == true)
        #expect(store.voiceLibrary.undo())
        var staleRange = sample
        staleRange.end = 2
        #expect(
            await !store.reviewVoiceExamples(
                .confirm(ids: [sample.id], personID: person), expectedExamples: [staleRange]))
        #expect(store.voiceLibrary.examples.first?.personID == nil)
        #expect(VoiceLibraryStore(loading: .immediate, directory: directory).examples.first?.personID == nil)
    }

    @Test func busyReviewPreparationWaitsCancellablyForSaving() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(library.upsert([], staged: true))
        let review = Task { try await library.reviewCandidates(for: UUID()) }
        await Task.yield()
        review.cancel()
        do {
            _ = try await review.value
            Issue.record("A cancelled review must finish without returning a queue.")
        }
        catch { #expect(error is CancellationError) }
    }

    @Test func selectedProfileIDsDistinguishBoundedProfileFromAllConfirmedSamples() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = UUID()
        let samples = try (0..<15).map { _ in try example(root: directory) }
        #expect(library.upsert(samples))
        #expect(library.confirm(ids: Set(samples.map(\.id)), personID: person))
        let initial = Set(
            try await library.matchingPeople(from: [Person(id: person)]).flatMap(\.voiceSamples).map(\.speakerID))
        #expect(initial.count == 12)
        #expect(library.examples.filter { $0.review == .confirmed }.count == 15)
        let removed = try #require(initial.first)
        #expect(library.reject(ids: [removed], personID: person))
        let selected = Set(
            try await library.matchingPeople(from: [Person(id: person)]).flatMap(\.voiceSamples).map(\.speakerID))
        #expect(selected.count == 12 && !selected.contains(removed))
        #expect(library.examples.first { $0.id == removed }?.rejectedPersonIDs == [person])
        #expect(library.undo())
        #expect(
            Set(try await library.matchingPeople(from: [Person(id: person)]).flatMap(\.voiceSamples).map(\.speakerID))
                == initial)
    }

    @Test func rejectedPairOnlyClearsMatchingSourcePersonAndSurvivesNewSpeakerLabels() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var sample = try example(root: directory)
        sample.origin = .savedSpeaker
        let rejected = UUID()
        let other = UUID()
        var meeting = Meeting(id: sample.meetingID, audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(
            id: sample.speakerID, label: "Speaker 1", track: "system", providerName: "Synthetic", personID: rejected,
            confirmed: true)
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 4, text: "Reviewed passage.", speakerID: speaker.id),
            .init(start: 5, end: 8, text: "Another passage.", speakerID: speaker.id),
        ]
        #expect(library.upsert([sample]))
        #expect(library.reject(ids: [sample.id], personID: rejected))
        let cleared = library.applyingDecisions(to: meeting)
        let reviewedID = try #require(cleared.transcript[0].speakerID)
        #expect(cleared.speakers.first { $0.id == reviewedID }?.personID == nil)
        #expect(cleared.speakers.first { $0.id == speaker.id }?.personID == rejected)
        meeting.speakers[0].personID = other
        #expect(library.applyingDecisions(to: meeting).speakers == meeting.speakers)
        #expect(library.confirm(ids: [sample.id], personID: other))
        let newSpeakerID = UUID()
        meeting.speakers[0].id = newSpeakerID
        meeting.speakers[0].personID = nil
        meeting.speakers[0].confirmed = false
        for index in meeting.transcript.indices { meeting.transcript[index].speakerID = newSpeakerID }
        let reprocessed = library.applyingDecisions(to: meeting)
        let exactID = try #require(reprocessed.transcript[0].speakerID)
        #expect(reprocessed.speakers.first { $0.id == exactID }?.personID == other)
        #expect(reprocessed.transcript[1].speakerID == newSpeakerID)
        #expect(library.decisions.isEmpty)
        #expect(library.undo())
        #expect(library.applyingDecisions(to: reprocessed).speakers == meeting.speakers)
    }

    @Test func clearStaysClearedAndStalePreparationCannotOverwriteReview() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = try example(root: directory)
        #expect(library.upsert([sample]))
        #expect(library.confirm(ids: [sample.id], personID: UUID()))
        #expect(library.clear(ids: [sample.id]))
        #expect(library.upsert([sample]))
        #expect(library.suggest(exampleID: sample.id, personID: UUID()))
        #expect(library.examples[0].manuallyCleared)
        #expect(library.examples[0].personID == nil && library.examples[0].suggestedPersonID == nil)
        #expect(library.undo())
        #expect(library.examples[0].review == .confirmed)
        let persisted = try #require(try VoiceLibraryPersistence(directory: directory).load())
        let encoded = try JSONEncoder().encode(persisted.undo)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("embeddings"))
    }

    @Test func reopenedMetadataAndReviewDoNotReadOrRewriteRepresentations() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = try example(root: directory)
        #expect(initial.upsert([sample]))
        let representationURL = directory.appendingPathComponent(
            "voice-library/representations/\(sample.id.uuidString).json")
        let original = try Data(contentsOf: representationURL)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.examples.count == 1 && reopened.examples[0].embeddings.isEmpty)
        #expect(reopened.confirm(ids: [sample.id], personID: UUID()))
        #expect(try Data(contentsOf: representationURL) == original)
        #expect(reopened.hydratedExample(id: sample.id)?.embeddings == sample.embeddings)
        reopened.releaseRepresentations()
        #expect(reopened.examples[0].embeddings.isEmpty)
    }

    @Test func committedRecordRecoveryWarningRemainsVisible() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(
            loading: .immediate,
            directory: directory,
            write: { data, url in
                if url.deletingLastPathComponent().lastPathComponent == "examples" {
                    throw ServiceError("Synthetic materialization failure")
                }
                try data.write(to: url, options: .atomic)
            })
        let sample = try example(root: directory)
        #expect(library.upsert([sample]))
        #expect(library.examples.contains { $0.id == sample.id })
        #expect(library.errorMessage?.contains("saved") == true)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.hydratedExample(id: sample.id) == sample)
    }

    @Test func failedAtomicWriteDoesNotPublishCorrectionOrUndo() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fails = VoiceWriteFailureFlag()
        let library = VoiceLibraryStore(
            loading: .immediate,
            directory: directory,
            write: { data, url in
                if fails.value { throw ServiceError("Synthetic write failure") }
                try data.write(to: url, options: .atomic)
            })
        let sample = try example(root: directory)
        #expect(library.upsert([sample]))
        fails.value = true
        #expect(!library.confirm(ids: [sample.id], personID: UUID()))
        #expect(library.examples[0].review == .unassigned)
        #expect(!library.canUndo && library.errorMessage != nil)
        #expect(VoiceLibraryStore(loading: .immediate, directory: directory).hydratedExample(id: sample.id) == sample)
    }

    @Test func recordedClustersAppearOnceInNeedsReviewAndAssignmentUpdatesTheMeeting() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var meeting = Meeting()
        let speaker = MeetingSpeaker(
            label: "Speaker 1", track: "system", providerName: "Speaker Diarization",
            voiceEmbedding: .init(type: type, values: [1, 0]))
        meeting.speakers = [speaker]
        #expect(library.ingest(meeting: meeting, directory: directory))
        #expect(library.ingest(meeting: meeting, directory: directory))
        let example = try #require(library.examples.first)
        #expect(library.examples.count == 1)
        #expect(example.groupID == speaker.id)
        #expect(example.needsReview)
        let personID = UUID()
        #expect(library.confirm(ids: [example.id], personID: personID))
        #expect(library.examples.allSatisfy { !$0.needsReview })
        let assigned = library.applyingDecisions(to: meeting)
        #expect(assigned.speakers.first?.personID == nil)
        #expect(library.decisions.isEmpty)
        #expect(library.undo())
        #expect(library.applyingDecisions(to: assigned).speakers.first?.personID == nil)
        #expect(library.examples.first?.needsReview == true)
        #expect(library.confirm(ids: [example.id], personID: personID))
        #expect(library.clear(ids: [example.id]))
        #expect(library.applyingDecisions(to: assigned).speakers.first?.personID == nil)
        #expect(library.undo())
        #expect(library.applyingDecisions(to: meeting).speakers.first?.personID == nil)
        #expect(library.reject(ids: [example.id], personID: personID))
        #expect(library.applyingDecisions(to: assigned).speakers.first?.personID == nil)
    }

    @Test func ingestKeepsCompatibleRunPodVectorWithoutAudioAndDoesNotInventConfirmation() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = Person(name: "Alex")
        var meeting = Meeting()
        let speaker = MeetingSpeaker(
            label: "speaker_01", track: "system", providerName: "RunPod",
            voiceScope: "legacy:rust:runpod", embedding: [1] + Array(repeating: 0, count: 255), personID: person.id)
        meeting.speakers = [speaker]
        #expect(library.ingest(meeting: meeting, directory: directory))
        let metadata = try #require(library.examples.first)
        let sample = try #require(library.hydratedExample(id: metadata.id))
        #expect(sample.range == nil && sample.audioRevision == nil)
        #expect(sample.embeddings.first?.type == .community1 && sample.embeddings.first?.isValid == true)
        #expect(sample.personID == nil && sample.suggestedPersonID == person.id && sample.review == .suggested)
        #expect(library.applyingDecisions(to: meeting) == meeting)
        #expect(library.ingest(meeting: meeting, directory: directory))
        #expect(library.examples.count == 1)
        #expect(library.confirm(ids: [sample.id], personID: person.id))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 1)
        let reviewed = library.applyingDecisions(to: meeting)
        #expect(reviewed.speakers.first?.id == speaker.id)
        #expect(reviewed.speakers.first?.personID == person.id)
        #expect(reviewed.speakers.first?.manuallyAssigned != true)
        #expect(library.decisions.isEmpty)
    }

    @Test func attachingAudioRevisionPreservesExistingModelRepresentations() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var sample = try example(root: directory)
        sample.audioRevision = nil
        #expect(library.upsert([sample]))
        var meeting = Meeting(id: sample.meetingID, audioFiles: ["system.wav"])
        meeting.speakers = [
            MeetingSpeaker(id: sample.speakerID, label: "speaker_01", track: "system", providerName: "Synthetic")
        ]
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        #expect(library.ingest(meeting: meeting, directory: folder))
        let saved = try #require(library.hydratedExample(id: sample.id))
        #expect(saved.audioRevision != nil && saved.embeddings == sample.embeddings)
        #expect(
            VoiceLibraryStore(loading: .immediate, directory: directory).hydratedExample(id: sample.id)?.embeddings
                == sample.embeddings)
    }

    @Test func replacedAudioPreventsExtractionButPreservesConfirmedVectors() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = try example(root: directory)
        let person = Person(name: "Alex")
        #expect(library.upsert([sample]))
        #expect(library.confirm(ids: [sample.id], personID: person.id))
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        try Data("replacement recording with different bytes".utf8).write(
            to: folder.appendingPathComponent("system.wav"))
        #expect(!library.audioIsCurrent(sample))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 1)
        #expect(!library.addRepresentation(exampleID: sample.id, embedding: sample.embeddings[0]))
    }

    @Test func savedProjectionColorsRemainIdempotentAcrossColdLibraryReads() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let first = try example(root: directory, start: 0, end: 4)
        let second = try example(
            root: directory, meetingID: first.meetingID, speakerID: first.speakerID, start: 5, end: 9)
        let speaker = MeetingSpeaker(
            id: first.speakerID, label: "sys_01", track: "system", providerName: "Synthetic")
        var meeting = Meeting(id: first.meetingID, audioFiles: ["system.wav"])
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 1, end: 3, speaker: speaker.label, text: "First voice", speakerID: speaker.id),
            .init(start: 6, end: 8, speaker: speaker.label, text: "Second voice", speakerID: speaker.id),
        ]
        #expect(library.upsert([first, second]))
        #expect(library.confirm(ids: [first.id], personID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!))
        #expect(library.confirm(ids: [second.id], personID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        let projected = library.applyingDecisions(to: meeting)
        let saved = MeetingSpeakerColors.assigning(projected, previous: meeting)
        #expect(Set(saved.speakers.compactMap(\.colorSlot)).count == 2)
        #expect(library.applyingDecisions(to: saved) == saved)
        #expect(library.applyingDecisions(to: saved) == saved)
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(saved))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.applyingDecisions(to: decoded) == decoded)
        try MeetingFolderStorage.write(saved, directory: directory)
        let folderDecoded = try MeetingFolderStorage.read(id: saved.id, directory: directory)
        let coldFolderLibrary = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(coldFolderLibrary.applyingDecisions(to: folderDecoded) == folderDecoded)
    }

    @Test(arguments: [false, true])
    func matchingExcerptReviewsPreserveWholeLabelIdentity(cleared: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let first = try example(root: directory, start: 0, end: 3)
        let second = try example(
            root: directory, meetingID: first.meetingID,
            speakerID: first.speakerID, start: 4, end: 7)
        let person: UUID? = cleared ? nil : UUID()
        var meeting = Meeting(id: first.meetingID, audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(
            id: first.speakerID, label: "Speaker 1", track: "system", providerName: "Synthetic")
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 3, speaker: speaker.label, text: "First synthetic passage.", speakerID: speaker.id),
            .init(start: 4, end: 7, speaker: speaker.label, text: "Second synthetic passage.", speakerID: speaker.id),
        ]
        #expect(library.upsert([first, second]))
        #expect(library.assign(meetingID: meeting.id, speakerID: speaker.id, personID: person))
        let projected = library.applyingDecisions(to: meeting)
        #expect(projected.speakers.count == 1)
        #expect(projected.speakers[0].id == speaker.id)
        #expect(projected.speakers[0].personID == person)
        #expect(projected.speakers[0].voiceReviewOrigin == nil)
        #expect(projected.transcript.allSatisfy { $0.speakerID == speaker.id })
        #expect(library.applyingDecisions(to: projected) == projected)
        // Reference review stays independent of an explicit transcript decision.
        let other = UUID()
        #expect(library.confirm(ids: [second.id], personID: other))
        let conflicted = library.applyingDecisions(to: projected)
        #expect(conflicted.transcript.allSatisfy { $0.speakerID == speaker.id })
        #expect(conflicted.speakers.first { $0.id == speaker.id }?.personID == person)
        #expect(library.examples.first { $0.id == second.id }?.personID == other)
        #expect(conflicted.speakers.filter { $0.voiceReviewOrigin?.evidenceOnly != true }.count == 1)
    }

    @Test func reviewedDetectedSpeakerLabelsAllRowsAndUndoRestoresSpeaker() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var sample = try example(root: directory, start: 2, end: 6)
        sample.origin = .savedSpeaker
        let personID = UUID()
        var meeting = Meeting(id: sample.meetingID, audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(id: sample.speakerID, label: "sys_01", track: "system", providerName: "Synthetic")
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 3, speaker: speaker.label, text: "Crosses the boundary", speakerID: speaker.id),
            .init(start: 3, end: 5, speaker: speaker.label, text: "Inside the excerpt", speakerID: speaker.id),
            .init(start: 7, end: 9, speaker: speaker.label, text: "Outside the excerpt", speakerID: speaker.id),
        ]
        #expect(library.upsert([sample]))
        #expect(library.confirm(ids: [sample.id], personID: personID))
        #expect(library.decisions.isEmpty)
        let projected = library.applyingDecisions(to: meeting)
        #expect(projected.transcript.map(\.text) == meeting.transcript.map(\.text))
        // The excerpt confirms the detected speaker identity. Every passage
        // assigned to that speaker inherits its name, including passages beyond
        // the selected review excerpt. Passage-specific corrections remain
        // covered by the conflicting-excerpt regression above.
        #expect(projected.transcript.allSatisfy { $0.speakerID == speaker.id })
        #expect(projected.speakers.count == 1)
        #expect(projected.speakers[0].personID == personID)
        #expect(projected.speakers[0].voiceReviewOrigin?.speakerID == speaker.id)
        #expect(library.applyingDecisions(to: projected) == projected)
        #expect(library.undo())
        let restored = library.applyingDecisions(to: projected)
        #expect(restored.transcript == meeting.transcript)
        #expect(restored.speakers == [speaker])
        #expect(restored.personIDs.isEmpty)
    }

    @Test func conflictingReviewsStayAnonymousAndExcludeAloneKeepsAttribution() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let first = try example(root: directory)
        var second = first
        second.id = UUID()
        let personID = UUID()
        let speaker = MeetingSpeaker(
            id: first.speakerID, label: "sys_01", track: "system", providerName: "Synthetic", personID: personID)
        var meeting = Meeting(id: first.meetingID, audioFiles: ["system.wav"])
        meeting.speakers = [speaker]
        meeting.transcript = [.init(start: 0, end: 4, speaker: speaker.label, text: "Example", speakerID: speaker.id)]
        #expect(library.upsert([first, second]))
        #expect(library.exclude(ids: [first.id]))
        #expect(library.applyingDecisions(to: meeting).speakers[0].personID == personID)
        #expect(library.confirm(ids: [first.id], personID: personID))
        // A subsequent correction updates compatible aliases. Load an already
        // conflicting explicit record to exercise preserved identity ambiguity.
        var conflicting = second
        conflicting.id = UUID()
        conflicting.personID = UUID()
        conflicting.review = .confirmed
        #expect(library.upsert([conflicting]))
        let projected = library.applyingDecisions(to: meeting)
        #expect(projected.speakers.count == 1)
        #expect(projected.speakers[0].personID == nil)
        #expect(projected.personIDs.isEmpty)
        #expect(library.applyingDecisions(to: projected) == projected)
    }

    @Test func manualNilSurvivesRecordedProviderRerun() {
        var meeting = Meeting()
        let speaker = MeetingSpeaker(
            label: "sys_01", track: "track0", providerName: "Synthetic", manuallyAssigned: true)
        meeting.speakers = [speaker]
        meeting.transcript = [.init(start: 0, end: 3, speaker: speaker.label, text: "Example", speakerID: speaker.id)]
        let replacement = MeetingSpeaker(label: "sys_02", track: "track0", providerName: "Synthetic")
        let result = LocalDiarizationResult(
            modelRevision: "synthetic",
            ranges: [
                .init(track: "track0", label: replacement.label, start: 0, end: 3)
            ], speakers: [replacement])
        let updated = LocalDiarizationAssignment.applying(result, to: meeting, fileCount: 1)
        #expect(updated.transcript == meeting.transcript)
        #expect(updated.speakers == [speaker])
    }

    @Test func unknownFutureSchemaCannotBeOverwritten() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var future = VoiceLibraryDocument()
        future.version = 999
        let url = directory.appendingPathComponent("voice-library.json")
        let original = try JSONEncoder().encode(future)
        try original.write(to: url)
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(!library.upsert([try example(root: directory)]))
        #expect(library.errorMessage != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func ingestIgnoresOtherTracksButRejectsOverlapOnTheSameTrack() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = try example(root: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        try Data("microphone fixture".utf8).write(to: folder.appendingPathComponent("microphone.wav"))
        var meeting = Meeting(id: sample.meetingID, audioFiles: ["system.wav", "microphone.wav"])
        let system = MeetingSpeaker(label: "sys_01", track: "system", providerName: "Synthetic")
        let microphone = MeetingSpeaker(label: "mic_01", track: "microphone", providerName: "Synthetic")
        meeting.speakers = [system, microphone]
        meeting.transcript = [
            .init(start: 0, end: 4, text: "System excerpt", speakerID: system.id),
            .init(start: 0, end: 4, text: "Microphone excerpt", speakerID: microphone.id),
        ]
        #expect(library.ingest(meeting: meeting, directory: folder))
        #expect(library.examples.count == 2)
        #expect(library.examples.allSatisfy { $0.embeddings.isEmpty })
        let secondDirectory = try root()
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        let second = VoiceLibraryStore(loading: .immediate, directory: secondDirectory)
        meeting.speakers[1].track = "system"
        #expect(second.ingest(meeting: meeting, directory: folder))
        #expect(second.examples.isEmpty)
    }

    @Test func changingProjectedSpeakerUpdatesOnlyItsReviewedExample() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = try example(root: directory)
        let firstPerson = UUID()
        let secondPerson = UUID()
        var meeting = Meeting(id: sample.meetingID, audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(id: sample.speakerID, label: "sys_01", track: "system", providerName: "Synthetic")
        meeting.speakers = [speaker]
        meeting.transcript = [.init(start: 0, end: 4, text: "Example", speakerID: speaker.id)]
        #expect(library.upsert([sample]))
        #expect(library.confirm(ids: [sample.id], personID: firstPerson))
        let projected = library.applyingDecisions(to: meeting)
        let derived = try #require(projected.speakers.first)
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: derived.id, personID: secondPerson,
                previousPersonID: firstPerson, exampleID: derived.voiceReviewExampleID))
        let changed = library.applyingDecisions(to: projected)
        #expect(changed.speakers[0].personID == secondPerson)
        #expect(library.decisions.isEmpty)
        #expect(library.undo())
        #expect(library.applyingDecisions(to: changed).speakers[0].personID == firstPerson)
    }

    @Test func undoNotifiesOnlyChangedMeetingsIncludingDecisionsWithoutExamples() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let unrelated = try example(root: directory)
        #expect(library.upsert([unrelated]))
        let meetingID = UUID()
        #expect(library.assign(meetingID: meetingID, speakerID: UUID(), personID: UUID()))
        var notified = Set<UUID>()
        library.didChange = { notified.formUnion($0) }
        #expect(library.undo())
        #expect(notified == [meetingID])
        #expect(!notified.contains(unrelated.meetingID))
    }

    @Test func repeatedRecoveryDoesNotAttachSavedVectorToKnownReplacementAudio() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = try example(root: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        var meeting = Meeting(id: sample.meetingID, audioFiles: ["system.wav"])
        meeting.speakers = [
            MeetingSpeaker(
                id: sample.speakerID, label: "speaker_01", track: "system",
                providerName: "Synthetic", voiceEmbedding: sample.embeddings[0], voiceSampleRange: sample.range,
                voiceSampleRevision: sample.audioRevision)
        ]
        try Data("replacement source bytes".utf8).write(to: folder.appendingPathComponent("system.wav"))
        #expect(library.ingest(meeting: meeting, directory: folder))
        let id = try #require(library.examples.first?.id)
        #expect(library.ingest(meeting: meeting, directory: folder))
        let recovered = try #require(library.resolveLegacyExample(exampleID: id, meeting: meeting, directory: folder))
        #expect(recovered.range == nil && recovered.firstPassage == nil)
        #expect(recovered.sourceResolutionIssue != nil && recovered.embeddings == sample.embeddings)
        #expect(library.examples.count == 1)
    }

    @Test func ingestNeverReattachesSavedVectorToReplacedAudio() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let sample = try example(root: directory)
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        var meeting = Meeting(id: sample.meetingID, audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(
            id: sample.speakerID, label: "sys_01", track: "system", providerName: "Synthetic",
            voiceEmbedding: sample.embeddings[0], voiceSampleRange: sample.range,
            voiceSampleRevision: sample.audioRevision)
        meeting.speakers = [speaker]
        #expect(library.ingest(meeting: meeting, directory: folder))
        #expect(library.hydratedExample(id: library.examples[0].id)?.embeddings == sample.embeddings)
        try Data("a different synthetic audio recording".utf8).write(to: folder.appendingPathComponent("system.wav"))
        #expect(library.ingest(meeting: meeting, directory: folder))
        #expect(library.examples.count == 1)
        #expect(!library.audioIsCurrent(library.examples[0]))
        #expect(library.hydratedExample(id: library.examples[0].id)?.embeddings == sample.embeddings)
    }
}

private final class VoiceWriteFailureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension VoiceLibraryTests {
    @Test func correctingExactAliasesIsAtomicPreservesConflictsAndUndoRestoresProvenance() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = UUID()
        let replacement = UUID()
        let conflictPerson = UUID()
        var first = try example(root: directory)
        first.personID = person
        first.review = .confirmed
        var alias = first
        alias.id = UUID()
        alias.groupID = UUID()
        var associated = first
        associated.id = UUID()
        associated.personID = nil
        associated.namedPersonID = person
        associated.review = .suggested
        var conflict = first
        conflict.id = UUID()
        conflict.personID = conflictPerson
        var otherSource = first
        otherSource.id = UUID()
        otherSource.source = "microphone"
        let originals = [first, alias, associated, conflict, otherSource]
        #expect(library.upsert(originals))
        #expect(library.confirm(ids: [first.id], personID: replacement))
        for id in [first.id, alias.id, associated.id] {
            let value = try #require(library.examples.first { $0.id == id })
            #expect(value.personID == replacement && value.review == .confirmed)
            #expect(value.rejectedPersonIDs.contains(person))
        }
        #expect(library.examples.first { $0.id == conflict.id }?.personID == conflictPerson)
        #expect(library.examples.first { $0.id == otherSource.id }?.personID == person)
        #expect(
            VoiceMatchReviewSession.referenceExamples(library.examples, personID: person).map(\.id) == [otherSource.id])
        #expect(library.undo())
        for original in originals {
            #expect(library.examples.first { $0.id == original.id }?.hasSameReviewEvidence(as: original) == true)
        }
        #expect(library.reject(ids: [first.id], personID: person))
        let scoped = library.referenceEvidence(for: person)
        #expect(VoiceMatchReviewSession.referenceExamples(scoped, personID: person).map(\.id) == [otherSource.id])
        #expect(
            VoiceMatchReviewSession.referenceExamples(library.examples, personID: person).map(\.id) == [otherSource.id])
        #expect(library.undo())
        #expect(library.exclude(ids: [first.id]))
        #expect(library.examples.filter { $0.excluded }.count == 3)
        #expect(library.undo())
        #expect(library.examples.allSatisfy { !$0.excluded })
    }
}

extension VoiceLibraryTests {
    @Test func indexedReferenceEvidenceIncludesExactRejectedAliasesAfterPublicationAndUndo() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = UUID()
        var associated = try example(root: directory)
        associated.namedPersonID = person
        associated.review = .suggested
        var rejection = associated
        rejection.id = UUID()
        rejection.namedPersonID = nil
        rejection.rejectedPersonIDs = [person]
        rejection.review = .rejected
        let unrelated = try example(root: directory)
        #expect(library.upsert([associated, rejection, unrelated]))
        let evidence = library.referenceEvidence(for: person)
        #expect(Set(evidence.map(\.id)) == [associated.id, rejection.id])
        #expect(VoiceMatchReviewSession.referenceExamples(evidence, personID: person).isEmpty)
        #expect(library.confirm(ids: [associated.id], personID: person))
        #expect(
            VoiceMatchReviewSession.referenceExamples(library.referenceEvidence(for: person), personID: person).count
                == 1)
        #expect(library.undo())
        #expect(
            VoiceMatchReviewSession.referenceExamples(library.referenceEvidence(for: person), personID: person).isEmpty)
    }
}

extension VoiceLibraryTests {
    @Test func confirmedAliasesContributeOncePerAudioAndModelToRecognitionProfile() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = Person(name: "Alex")
        let first = try example(root: directory)
        var alias = first
        alias.id = UUID()
        var otherModel = first
        otherModel.id = UUID()
        let alternateType = EmbeddingType(
            modelID: "other-synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2,
            normalization: "unitL2")
        otherModel.embeddings = [.init(type: alternateType, values: [1, 0])]
        let distinctAudio = try example(root: directory, meetingID: first.meetingID, start: 10, end: 14)
        #expect(library.upsert([first, alias, otherModel, distinctAudio]))
        #expect(library.confirm(ids: [first.id, distinctAudio.id], personID: person.id))
        let profile = try #require(try await library.matchingPeople(from: [person]).first)
        #expect(profile.voiceSamples.count == 3)
        #expect(profile.voiceSamples.filter { $0.resolvedVoiceEmbedding.type == type }.count == 2)
        #expect(profile.voiceSamples.filter { $0.resolvedVoiceEmbedding.type == alternateType }.count == 1)
        #expect(library.examples.count == 4)
    }
}

extension VoiceLibraryTests {
    @Test func reassigningExactAliasesBackRemovesRejectionOfCurrentPerson() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = UUID()
        let other = UUID()
        var first = try example(root: directory)
        first.personID = person
        first.review = .confirmed
        var alias = first
        alias.id = UUID()
        #expect(library.upsert([first, alias]))
        #expect(library.confirm(ids: [first.id], personID: other))
        #expect(library.examples.allSatisfy { $0.personID == other && $0.rejectedPersonIDs.contains(person) })
        #expect(library.confirm(ids: [alias.id], personID: person))
        #expect(
            library.examples.allSatisfy {
                $0.personID == person && !$0.rejectedPersonIDs.contains(person) && $0.rejectedPersonIDs.contains(other)
            })
        #expect(library.undo())
        #expect(library.examples.allSatisfy { $0.personID == other && $0.rejectedPersonIDs.contains(person) })
    }
}

extension VoiceLibraryTests {
    @Test(arguments: [false, true])
    func correctingProposedIdentityRecordsTheSameDecisionForExistingAndNewPeople(createPerson: Bool) throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let proposed = UUID()
        let replacement = UUID()
        var sample = try example(root: directory)
        sample.suggestedPersonID = proposed
        sample.review = .suggested
        var alias = sample
        alias.id = UUID()
        #expect(library.upsert([sample, alias]))
        if createPerson {
            #expect(library.nameGroup(ids: [sample.id], confirmedExampleID: sample.id, personID: replacement))
        }
        else {
            #expect(library.confirm(ids: [sample.id], personID: replacement))
        }
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.examples.count == 2)
        #expect(
            reopened.examples.allSatisfy {
                $0.personID == replacement && $0.review == .confirmed && $0.suggestedPersonID == nil
                    && $0.rejectedPersonIDs == [proposed]
            })
        #expect(reopened.undo())
        #expect(
            reopened.examples.allSatisfy {
                $0.personID == nil && $0.review == .suggested && $0.suggestedPersonID == proposed
                    && $0.rejectedPersonIDs.isEmpty
            })
    }
}

extension VoiceLibraryTests {
    @Test func clearingExactAliasesKeepsProfilesReferencesAndMeetingProjectionConsistentThroughUndo() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = Person(name: "Alex")
        let first = try example(root: directory)
        var alias = first
        alias.id = UUID()
        alias.groupID = UUID()
        let other = try example(root: directory, meetingID: first.meetingID, start: 10, end: 14)
        var meeting = Meeting(id: first.meetingID, audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(
            id: first.speakerID, label: "Speaker 1", track: "system", providerName: "Synthetic")
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 4, text: "First passage.", speakerID: speaker.id),
            .init(start: 10, end: 14, text: "Another passage.", speakerID: speaker.id),
        ]
        #expect(library.upsert([first, alias, other]))
        #expect(library.confirm(ids: [first.id, other.id], personID: person.id))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.count == 2)
        #expect(library.clear(ids: [first.id]))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        let cleared = reopened.examples.filter { [first.id, alias.id].contains($0.id) }
        #expect(cleared.count == 2)
        #expect(cleared.allSatisfy { $0.personID == nil && $0.manuallyCleared && $0.review == .unassigned })
        #expect(reopened.examples.first { $0.id == other.id }?.personID == person.id)
        #expect((try await reopened.matchingPeople(from: [person]))[0].voiceSamples.map(\.speakerID) == [other.id])
        #expect(
            VoiceMatchReviewSession.referenceExamples(reopened.referenceEvidence(for: person.id), personID: person.id)
                .map(\.id) == [other.id])
        let projected = reopened.applyingDecisions(to: meeting)
        let firstSpeaker = projected.transcript[0].speakerID
        let secondSpeaker = projected.transcript[1].speakerID
        #expect(projected.speakers.first { $0.id == firstSpeaker }?.personID == nil)
        #expect(projected.speakers.first { $0.id == secondSpeaker }?.personID == person.id)
        #expect(reopened.undo())
        #expect(
            reopened.examples.allSatisfy { $0.personID == person.id && !$0.manuallyCleared && $0.review == .confirmed })
        #expect((try await reopened.matchingPeople(from: [person]))[0].voiceSamples.count == 2)
        #expect(
            VoiceMatchReviewSession.referenceExamples(reopened.referenceEvidence(for: person.id), personID: person.id)
                .count == 2)
        let restored = reopened.applyingDecisions(to: projected)
        #expect(
            restored.transcript.allSatisfy { row in
                restored.speakers.first { $0.id == row.speakerID }?.personID == person.id
            })
    }

    @Test func restoringIgnoredExactAudioKeepsOtherExplicitIdentitiesUnchanged() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var first = try example(root: directory)
        first.personID = UUID()
        first.review = .confirmed
        first.excluded = true
        var alias = first
        alias.id = UUID()
        var conflict = first
        conflict.id = UUID()
        conflict.personID = UUID()
        #expect(library.upsert([first, alias, conflict]))
        #expect(library.exclude(ids: [first.id], excluded: false))
        #expect(library.examples.filter { [first.id, alias.id].contains($0.id) }.allSatisfy { !$0.excluded })
        #expect(library.examples.first(where: { $0.id == conflict.id })?.hasSameReviewEvidence(as: conflict) == true)
        #expect(library.undo())
        #expect(library.examples.allSatisfy { $0.excluded })
    }
}

extension VoiceLibraryTests {
    @Test func clearingConflictingIdentityPreservesTheRemainingConfirmationAndUndo() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let firstPerson = Person(name: "Alex")
        let secondPerson = Person(name: "Sam")
        var first = try example(root: directory)
        first.personID = firstPerson.id
        first.review = .confirmed
        var conflict = first
        conflict.id = UUID()
        conflict.personID = secondPerson.id
        var meeting = Meeting(id: first.meetingID, audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(
            id: first.speakerID, label: "Speaker 1", track: "system", providerName: "Synthetic")
        meeting.speakers = [speaker]
        meeting.transcript = [.init(start: 0, end: 4, text: "A passage.", speakerID: speaker.id)]
        #expect(library.upsert([first, conflict]))
        #expect(library.clear(ids: [first.id]))
        let effective = VoiceExactReviewDecisions(library.examples)
        let remaining = try #require(library.examples.first { $0.id == conflict.id })
        #expect(!effective.applying(to: remaining).manuallyCleared)
        #expect(effective.applying(to: remaining).personID == secondPerson.id)
        #expect(
            VoiceMatchReviewSession.referenceExamples(
                library.referenceEvidence(for: secondPerson.id), personID: secondPerson.id
            ).map(\.id) == [conflict.id])
        let profiles = try await library.matchingPeople(from: [firstPerson, secondPerson])
        #expect(profiles[0].voiceSamples.isEmpty)
        #expect(profiles[1].voiceSamples.count == 1)
        let projected = library.applyingDecisions(to: meeting)
        let projectedSpeaker = projected.transcript[0].speakerID
        #expect(projected.speakers.first { $0.id == projectedSpeaker }?.personID == secondPerson.id)
        #expect(library.undo())
        #expect(library.examples.first(where: { $0.id == first.id })?.personID == firstPerson.id)
        #expect(library.examples.first(where: { $0.id == conflict.id })?.personID == secondPerson.id)
        #expect(library.examples.allSatisfy { !$0.manuallyCleared })
        #expect(
            (try await library.matchingPeople(from: [firstPerson, secondPerson])).allSatisfy { $0.voiceSamples.isEmpty }
        )
        let restored = library.applyingDecisions(to: projected)
        let restoredSpeaker = restored.transcript[0].speakerID
        #expect(restored.speakers.first { $0.id == restoredSpeaker }?.personID == nil)
    }
}

extension VoiceLibraryTests {
    @Test func correctingIgnoreToRejectionRestoresAudioForOtherPeopleAndUndoKeepsOtherDecisions() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = UUID()
        let sample = try example(root: directory)
        let other = try example(root: directory)
        #expect(library.upsert([sample, other]))
        #expect(library.exclude(ids: [sample.id]))
        #expect(library.confirm(ids: [other.id], personID: person))
        #expect(library.reject(ids: [sample.id], personID: person, restoreExcluded: true))
        let updated = try #require(library.examples.first { $0.id == sample.id })
        #expect(!updated.excluded && updated.rejectedPersonIDs.contains(person))
        #expect(try await library.reviewCandidates(for: person).isEmpty)
        #expect(library.undo())
        #expect(library.examples.first { $0.id == sample.id }?.excluded == true)
        #expect(library.examples.first { $0.id == other.id }?.personID == person)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(try await reopened.reviewCandidates(for: person).isEmpty)
        #expect(try await reopened.identificationGroups().flatMap(\.examples).allSatisfy { $0.id != sample.id })
    }
}
