import Foundation
import Synchronization
import Testing

@testable import GdayMeetings

@MainActor struct VoiceProjectionInvalidationTests {
    private func fixture(directory: URL) throws -> (Meeting, VoiceExample) {
        var meeting = Meeting(title: "Synthetic meeting", audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(label: "Speaker 1", track: "system", providerName: "Synthetic")
        meeting.speakers = [speaker]
        meeting.transcript = [.init(start: 0, end: 2, text: "Synthetic speech", speakerID: speaker.id)]
        let folder = try MeetingFolderLocation.newFolder(id: meeting.id, date: meeting.createdAt, directory: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("system.wav")
        try Data("synthetic audio".utf8).write(to: file)
        var example = VoiceExample(
            meetingID: meeting.id, speakerID: speaker.id, source: "system", audioFile: "system.wav",
            audioRevision: VoiceLibraryStore.revision(url: file), start: 0, end: 2, review: .suggested)
        example.transcriptAssociation = .init(personID: UUID(), score: 0.9, margin: 0.3, policy: .default)
        return (meeting, example)
    }

    @Test(arguments: ["representation", "suggestion", "canonicalRepresentation", "failedCanonical"])
    func withdrawingMachineEvidenceNotifiesProjectionWithoutRematching(_ mutation: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (meeting, original) = try fixture(directory: directory)
        var example = original
        #expect(library.upsert([example]))
        var projections: [Set<UUID>] = []
        var reviews: [Set<UUID>] = []
        library.didChangeProjection = { projections.append($0) }
        library.didChange = { reviews.append($0) }
        if mutation == "suggestion" {
            #expect(library.suggest(exampleID: example.id, personID: nil))
        }
        else {
            example.embeddings = [.init(type: .community1, values: [1] + Array(repeating: 0, count: 255))]
            let staged = mutation.contains("Canonical") || mutation == "canonicalRepresentation"
            #expect(library.upsert([example], staged: staged))
            if staged {
                #expect(projections.isEmpty && reviews.isEmpty)
                let commit = try #require(try library.beginCanonicalCommit())
                var state: VoiceLibraryPersistence.Snapshot?
                if mutation != "failedCanonical" {
                    let backend = try VoiceLibraryPersistence(directory: directory)
                    backend.adopt(commit.persistence)
                    try backend.commit(previous: commit.previous, next: commit.next)
                    state = backend.snapshot()
                }
                library.finishCanonicalCommit(commit, state: state, committed: mutation != "failedCanonical")
                #expect(library.canProjectDecisions)
            }
        }
        #expect(reviews.isEmpty)
        #expect(projections == (mutation == "failedCanonical" ? [] : [[meeting.id]]))
        if mutation == "failedCanonical" { #expect(library.examples[0].transcriptAssociation != nil) }
    }

    @Test func humanConfirmationRetainsMatchingIntentWithoutDuplicateProjectionCallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (meeting, example) = try fixture(directory: directory)
        #expect(library.upsert([example]))
        var projections: [Set<UUID>] = []
        var reviews: [Set<UUID>] = []
        library.didChangeProjection = { projections.append($0) }
        library.didChange = { reviews.append($0) }
        #expect(library.confirm(ids: [example.id], personID: UUID()))
        #expect(reviews == [[meeting.id]])
        #expect(projections.isEmpty)
    }

    @Test func speakerDecisionNotifiesOnlyItsChangedMeeting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (first, firstExample) = try fixture(directory: directory)
        let (second, secondExample) = try fixture(directory: directory)
        #expect(library.upsert([firstExample, secondExample]))
        #expect(library.assign(meetingID: first.id, speakerID: firstExample.speakerID, personID: UUID()))
        var reviews: [Set<UUID>] = []
        library.didChange = { reviews.append($0) }
        #expect(library.assign(meetingID: second.id, speakerID: secondExample.speakerID, personID: UUID()))
        #expect(reviews == [[second.id]])
    }

    @Test func identicalRepresentationRetainsMachineAttributionWithoutPublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var (_, example) = try fixture(directory: directory)
        example.embeddings = [.init(type: .community1, values: [1] + Array(repeating: 0, count: 255))]
        #expect(library.upsert([example]))
        let revision = library.representationsRevision
        var notifications = 0
        library.didChange = { _ in notifications += 1 }
        library.didChangeProjection = { _ in notifications += 1 }
        #expect(library.upsert([example]))
        #expect(library.examples.first?.transcriptAssociation == example.transcriptAssociation)
        #expect(library.representationsRevision == revision)
        #expect(notifications == 0)
    }

    @Test(arguments: [false, true])
    func transcriptIdentityCorrectionPreservesIndependentReferenceDecisions(confirmed: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (meeting, original) = try fixture(directory: directory)
        var example = original
        let prior = try #require(example.transcriptAssociation?.personID)
        example.suggestedPersonID = prior
        example.namedPersonID = UUID()
        example.rejectedPersonIDs = [UUID()]
        if confirmed {
            example.personID = prior
            example.review = .confirmed
        }
        #expect(library.upsert([example]))
        #expect(
            library.assign(
                meetingID: meeting.id, speakerID: example.speakerID, personID: confirmed ? UUID() : prior,
                preservePreviousSpeakerDecision: false, updateReferenceEvidence: false, relatedExampleID: example.id))
        let saved = try #require(library.examples.first)
        #expect(saved.personID == example.personID && saved.review == example.review)
        #expect(saved.namedPersonID == example.namedPersonID && saved.rejectedPersonIDs == example.rejectedPersonIDs)
        #expect(saved.transcriptAssociation == nil && saved.suggestedPersonID == nil)
    }

    @Test(arguments: [false, true])
    func undoCreatedPersonDiscardsMachineUsesButProtectsExplicitUses(manual: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let (first, original) = try fixture(directory: directory)
        var anchor = original
        anchor.transcriptAssociation = nil
        anchor.review = .unassigned
        var (second, candidate) = try fixture(directory: directory)
        try await store.insertImportedMeeting(first)
        try await store.insertImportedMeeting(second)
        await store.flushVoiceAssignmentRefresh()
        let library = store.voiceLibrary
        let reviewChanged = library.didChange
        let projectionChanged = library.didChangeProjection
        library.didChange = nil
        library.didChangeProjection = nil
        #expect(library.upsert([anchor]))
        let receipt = try #require(
            await store.nameVoiceGroupResult(
                exampleIDs: [anchor.id], confirmedExampleID: anchor.id, personID: nil,
                newPersonName: "Example Person", expectedExamples: [anchor]))
        await store.flushVoiceAssignmentRefresh()
        let person = try #require(receipt.personID)
        candidate.transcriptAssociation?.personID = person
        #expect(library.upsert([candidate]))
        if manual {
            second.speakers[0].personID = person
            second.speakers[0].manuallyAssigned = true
            #expect(await store.updateMeeting(second))
        }
        else {
            await store.refreshVoiceAssignments(meetingIDs: [second.id], recomputeSuggestions: false)
        }
        #expect(try store.libraryIndex?.count(personID: person) == 2)
        library.didChange = reviewChanged
        library.didChangeProjection = projectionChanged
        let undone = await store.reviewVoiceExamples(.undo, expectedUndoID: receipt.undoID)
        await store.flushVoiceAssignmentRefresh()
        #expect(undone == !manual)
        #expect(store.people.contains { $0.id == person } == manual)
        #expect(library.deletedPersonIDs.contains(person) == !manual)
        if !manual {
            #expect(library.examples.first { $0.id == candidate.id }?.transcriptAssociation == nil)
            #expect(try store.libraryIndex?.count(personID: person) == 0)
        }
    }

    @Test(arguments: ["unresolved", "manual", "conflict", "tentative", "automatic", "tentativeWithCertain"])
    func startupQueuesOnlyApplicableAutomaticAttendance(_ kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Example Person")
        var (meeting, example) = try fixture(directory: directory)
        example.transcriptAssociation?.personID = person
        if kind == "tentative" || kind == "tentativeWithCertain" {
            example.transcriptAssociation?.tier = .tentative
            example.transcriptAssociation?.score = 0.4
        }
        if kind == "unresolved" {
            meeting.speakers = []
            meeting.transcript[0].speakerID = nil
        }
        if kind == "manual" {
            meeting.speakers[0].manuallyAssigned = true
            meeting.speakers[0].personID = UUID()
        }
        if kind == "tentativeWithCertain" {
            meeting.speakers[0].personID = person
            meeting.speakers[0].voiceReviewOrigin = .init(
                speakerID: meeting.speakers[0].id, transcriptAssociationTier: .tentative)
            var certain = MeetingSpeaker(label: "Speaker 2", track: "system", providerName: "Synthetic")
            certain.personID = person
            certain.manuallyAssigned = true
            meeting.speakers.append(certain)
        }
        try await store.insertImportedMeeting(meeting)
        await store.flushVoiceAssignmentRefresh()
        store.voiceLibrary.didChange = nil
        store.voiceLibrary.didChangeProjection = nil
        var examples = [example]
        if kind == "conflict" {
            var other = example
            other.id = UUID()
            other.transcriptAssociation?.personID = UUID()
            examples.append(other)
        }
        #expect(store.voiceLibrary.upsert(examples))
        for launch in 0..<2 {
            let reopened = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
            await reopened.libraryMonitor?.stop()
            reopened.libraryMonitor = nil
            let reads = Mutex(0)
            reopened.meetingLoadReader = { id, root in
                reads.withLock { $0 += 1 }
                return try MeetingFolderStorage.read(id: id, directory: root)
            }
            #expect(reopened.voiceLibrary.isLoaded)
            await reopened.flushVoiceAssignmentRefresh()
            #expect(reads.withLock { $0 } == (kind == "automatic" && launch == 0 ? 1 : 0))
            #expect(
                try reopened.libraryIndex?.count(personID: person)
                    == (["automatic", "tentativeWithCertain"].contains(kind) ? 1 : 0))
        }
    }
}
