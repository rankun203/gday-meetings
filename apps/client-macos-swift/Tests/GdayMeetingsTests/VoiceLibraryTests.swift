import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct VoiceLibraryTests {
    let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2,
        normalization: "unitL2")

    private func seededLegacyLibrary(directory: URL, person: Person) -> VoiceLibraryStore {
        let library = VoiceLibraryStore(directory: directory)
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

    @Test func onlyReviewedPlayableExamplesEnrollAndLaterSamplesStayUnreviewed() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let person = Person(name: "Alex")
        let library = VoiceLibraryStore(directory: directory)
        let first = try example(root: directory)
        #expect(library.upsert([first]))
        #expect(library.matchingPeople(from: [person])[0].voiceSamples.isEmpty)
        #expect(library.confirm(ids: [first.id], personID: person.id))
        #expect(library.matchingPeople(from: [person])[0].voiceSamples.count == 1)
        #expect(
            library.recordSample(
                meetingID: first.meetingID, speakerID: first.speakerID,
                range: .init(audioFile: "system.wav", source: "system", start: 5, end: 9),
                embedding: first.embeddings[0], suggestion: person.id))
        #expect(library.examples.count == 2)
        #expect(library.examples.filter { $0.review == .confirmed }.count == 1)
        #expect(library.matchingPeople(from: [person])[0].voiceSamples.count == 1)
    }

    @Test func confirmedSamplesWithoutAudioCanSeedTheirMatchingModel() throws {
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
        #expect(library.matchingPeople(from: [person])[0].voiceSamples.count == 1)
    }

    @Test func rejectionSurvivesReopeningAndSuppressesSimilarVoiceInNewRecording() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let personID = UUID()
        var rejected = try example(root: directory)
        rejected.suggestedPersonID = personID
        rejected.review = .suggested
        let library = VoiceLibraryStore(directory: directory)
        #expect(library.upsert([rejected]))
        #expect(library.reject(ids: [rejected.id], personID: personID))
        let reopened = VoiceLibraryStore(directory: directory)
        let candidate = try example(root: directory)
        #expect(reopened.upsert([candidate]))
        #expect(reopened.suggest(exampleID: candidate.id, personID: personID))
        #expect(reopened.examples.first { $0.id == candidate.id }?.suggestedPersonID == nil)
        #expect(reopened.examples.first { $0.id == rejected.id }?.rejectedPersonIDs == [personID])
    }

    @Test func clearStaysClearedAndStalePreparationCannotOverwriteReview() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
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
        let initial = VoiceLibraryStore(directory: directory)
        let sample = try example(root: directory)
        #expect(initial.upsert([sample]))
        let representationURL = directory.appendingPathComponent(
            "voice-library/representations/\(sample.id.uuidString).json")
        let original = try Data(contentsOf: representationURL)
        let reopened = VoiceLibraryStore(directory: directory)
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
        let reopened = VoiceLibraryStore(directory: directory)
        #expect(reopened.hydratedExample(id: sample.id) == sample)
    }

    @Test func failedAtomicWriteDoesNotPublishCorrectionOrUndo() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var fails = false
        let library = VoiceLibraryStore(
            directory: directory,
            write: { data, url in
                if fails { throw ServiceError("Synthetic write failure") }
                try data.write(to: url, options: .atomic)
            })
        let sample = try example(root: directory)
        #expect(library.upsert([sample]))
        fails = true
        #expect(!library.confirm(ids: [sample.id], personID: UUID()))
        #expect(library.examples[0].review == .unassigned)
        #expect(!library.canUndo && library.errorMessage != nil)
        #expect(VoiceLibraryStore(directory: directory).hydratedExample(id: sample.id) == sample)
    }

    @Test func newLiveSampleKeepsSuggestionUnlessReviewedEvidenceRejectsIt() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
        let sample = try example(root: directory)
        let personID = UUID()
        let range = try #require(sample.range)
        #expect(
            library.recordSample(
                meetingID: sample.meetingID, speakerID: sample.speakerID,
                range: range, embedding: sample.embeddings[0], suggestion: personID))
        let recorded = try #require(library.examples.first)
        #expect(recorded.suggestedPersonID == personID && recorded.review == .suggested)
        #expect(library.reject(ids: [recorded.id], personID: personID))
        let nextSpeakerID = UUID()
        #expect(
            library.recordSample(
                meetingID: sample.meetingID, speakerID: nextSpeakerID,
                range: range, embedding: sample.embeddings[0], suggestion: personID))
        let next = try #require(library.examples.first { $0.speakerID == nextSpeakerID })
        #expect(next.suggestedPersonID == nil && next.review == .unassigned)
    }

    @Test func ingestKeepsCompatibleRunPodVectorWithoutAudioAndDoesNotInventConfirmation() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
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
        #expect(library.matchingPeople(from: [person])[0].voiceSamples.count == 1)
        #expect(library.applyingDecisions(to: meeting) == meeting)
    }

    @Test func attachingAudioRevisionPreservesExistingModelRepresentations() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
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
        #expect(VoiceLibraryStore(directory: directory).hydratedExample(id: sample.id)?.embeddings == sample.embeddings)
    }

    @Test func replacedAudioPreventsExtractionButPreservesConfirmedVectors() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
        let sample = try example(root: directory)
        let person = Person(name: "Alex")
        #expect(library.upsert([sample]))
        #expect(library.confirm(ids: [sample.id], personID: person.id))
        let folder = try MeetingFolderLocation.resolve(id: sample.meetingID, directory: directory)
        try Data("replacement recording with different bytes".utf8).write(
            to: folder.appendingPathComponent("system.wav"))
        #expect(!library.audioIsCurrent(sample))
        #expect(library.matchingPeople(from: [person])[0].voiceSamples.count == 1)
        #expect(!library.addRepresentation(exampleID: sample.id, embedding: sample.embeddings[0]))
    }

    @Test func exactReviewProjectionIsIdempotentAndUndoRestoresSpeaker() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
        let sample = try example(root: directory, start: 2, end: 6)
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
        let projected = library.applyingDecisions(to: meeting)
        #expect(projected.transcript.map(\.text) == meeting.transcript.map(\.text))
        #expect(projected.transcript[0].speakerID == speaker.id)
        #expect(projected.transcript[1].speakerID != speaker.id)
        #expect(projected.transcript[2].speakerID == speaker.id)
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
        let library = VoiceLibraryStore(directory: directory)
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
        #expect(library.confirm(ids: [second.id], personID: UUID()))
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
        let library = VoiceLibraryStore(directory: directory)
        #expect(!library.upsert([try example(root: directory)]))
        #expect(library.errorMessage != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func ingestIgnoresOtherTracksButRejectsOverlapOnTheSameTrack() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
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
        let second = VoiceLibraryStore(directory: secondDirectory)
        meeting.speakers[1].track = "system"
        #expect(second.ingest(meeting: meeting, directory: folder))
        #expect(second.examples.isEmpty)
    }

    @Test func changingProjectedSpeakerUpdatesOnlyItsReviewedExample() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(directory: directory)
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
        let library = VoiceLibraryStore(directory: directory)
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
        let library = VoiceLibraryStore(directory: directory)
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
        let library = VoiceLibraryStore(directory: directory)
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
