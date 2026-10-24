import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct VoiceGroupNamingTests {
    private let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2, normalization: "unitL2")
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func sample(root: URL, meeting: UUID = UUID(), start: Double = 0, vector: [Double] = [1, 0]) throws
        -> VoiceExample
    {
        let folder = try MeetingFolderLocation.newFolder(id: meeting, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("system.wav")
        if !FileManager.default.fileExists(atPath: file.path) { try Data("synthetic audio".utf8).write(to: file) }
        return VoiceExample(
            meetingID: meeting, speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: VoiceLibraryStore.revision(url: file), start: start, end: start + 4,
            embeddings: [.init(type: type, values: vector)])
    }

    @Test func exactAliasesStayStoredButDoNotReturnAfterNamingOrConfirming() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let first = try sample(root: root)
        var alias = first
        alias.id = UUID()
        alias.speakerID = UUID()
        alias.groupID = UUID()
        let next = try sample(root: root, meeting: first.meetingID, start: 8)
        let person = UUID()
        #expect(library.upsert([first, alias, next]))
        let group = try #require(try await library.identificationGroups().first)
        #expect(group.examples.count == 2)
        #expect(Set(group.evidenceExamples.map(\.id)) == [first.id, alias.id, next.id])
        let anchor = try #require(group.examples.first { VoiceReviewSelection.sameAudio($0, first) })
        #expect(
            library.nameGroup(
                ids: Set(group.evidenceExamples.map(\.id)), confirmedExampleID: anchor.id, personID: person))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(reopened.examples.count == 3)
        #expect(Set(reopened.examples.filter { $0.review == .confirmed }.map(\.id)) == [first.id, alias.id])
        #expect(reopened.examples.first { $0.id == next.id }?.namedPersonID == person)
        #expect(try await reopened.reviewCandidates(for: person).isEmpty)
        let refreshed = try await reopened.identificationGroups().flatMap(\.examples)
        #expect(refreshed.filter { VoiceReviewSelection.sameAudio($0, first) }.count == 1)
        #expect(Set(refreshed.map(\.id)).isSubset(of: [first.id, alias.id, next.id]))
        #expect(reopened.undo())
        #expect(try await reopened.identificationGroups().flatMap(\.examples).count == 2)
        #expect(reopened.confirm(ids: [anchor.id], personID: person))
        let confirmed = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(try await confirmed.reviewCandidates(for: person).isEmpty)
        #expect(
            try await confirmed.identificationGroups().flatMap(\.examples).filter {
                VoiceReviewSelection.sameAudio($0, first)
            }.count == 1)
        #expect(confirmed.undo())
        #expect(confirmed.exclude(ids: [anchor.id]))
        let ignored = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(try await ignored.identificationGroups().flatMap(\.examples).map(\.id) == [next.id])
        #expect(ignored.examples.count == 3)
    }

    @Test func rejectingVisibleAliasKeepsOneQuestionAndAllRawSnapshots() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let first = try sample(root: root)
        var alias = first
        alias.id = UUID()
        alias.groupID = UUID()
        #expect(library.upsert([first, alias]))
        let displayed = try #require(try await library.identificationGroups().flatMap(\.examples).first)
        let person = UUID()
        #expect(library.reject(ids: [displayed.id], personID: person))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: root)
        let groups = try await reopened.identificationGroups()
        #expect(groups.flatMap(\.examples).count == 1)
        let evidence = groups.flatMap(\.evidenceExamples)
        #expect(evidence.count == 2)
        #expect(Set(evidence.filter { $0.rejectedPersonIDs.contains(person) }.map(\.id)) == [first.id, alias.id])
        #expect(try await reopened.reviewCandidates(for: person).isEmpty)
        #expect(reopened.undo())
        #expect(reopened.examples.allSatisfy { $0.rejectedPersonIDs.isEmpty })
    }

    @Test func groupNamingPersistsAssociationsWithoutEnrollingUnheardMembers() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let first = try sample(root: root)
        let second = try sample(root: root, meeting: first.meetingID, start: 5)
        let person = Person(name: "Alex")
        #expect(library.upsert([first, second]))
        #expect(library.nameGroup(ids: [first.id, second.id], confirmedExampleID: first.id, personID: person.id))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(reopened.examples.first { $0.id == first.id }?.review == .confirmed)
        let associated = try #require(reopened.examples.first { $0.id == second.id })
        #expect(associated.personID == nil && associated.namedPersonID == person.id && associated.review == .suggested)
        #expect(try await reopened.matchingPeople(from: [person])[0].voiceSamples.map(\.speakerID) == [first.id])
        try await reopened.suggestReviewedPeopleResult(from: [])
        #expect(reopened.examples.first { $0.id == second.id }?.suggestedPersonID == person.id)
        #expect(try await reopened.reviewCandidates(for: person.id).isEmpty)
        #expect(reopened.reject(ids: [second.id], personID: person.id))
        try await reopened.suggestReviewedPeopleResult(from: [person])
        #expect(try await reopened.reviewCandidates(for: person.id).isEmpty)
        #expect(reopened.examples.first { $0.id == second.id }?.namedPersonID == nil)
        #expect(reopened.undo())
        #expect(reopened.examples.first { $0.id == second.id }?.namedPersonID == person.id)
        #expect(reopened.undo())
        #expect(reopened.examples.allSatisfy { $0.personID == nil && $0.namedPersonID == nil })
    }

    @Test func explicitAnchorCorrectionPreservesOtherConfirmedGroupMembers() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let first = try sample(root: root)
        let second = try sample(root: root, meeting: first.meetingID, start: 5)
        let old = UUID()
        let chosen = UUID()
        #expect(library.upsert([first, second]))
        #expect(library.confirm(ids: [first.id, second.id], personID: old))
        #expect(library.nameGroup(ids: [first.id, second.id], confirmedExampleID: first.id, personID: chosen))
        #expect(library.examples.first { $0.id == first.id }?.personID == chosen)
        #expect(library.examples.first { $0.id == first.id }?.rejectedPersonIDs == [old])
        #expect(library.examples.first { $0.id == second.id }?.personID == old)
        #expect(library.undo())
        #expect(library.examples.allSatisfy { $0.personID == old })
    }

    @Test func ignoredAndRejectedExactAudioSurvivesRegeneratedProviderIDs() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let person = Person(name: "Alex")
        let seed = try sample(root: root)
        let candidate = try sample(root: root)
        #expect(library.upsert([seed, candidate]))
        #expect(library.confirm(ids: [seed.id], personID: person.id))
        #expect(library.reject(ids: [candidate.id], personID: person.id))
        var replay = candidate
        replay.id = UUID()
        replay.speakerID = UUID()
        #expect(library.upsert([replay]))
        #expect(library.suggest(exampleID: replay.id, personID: person.id))
        #expect(library.examples.first { $0.id == replay.id }?.suggestedPersonID == nil)
        #expect(try await library.reviewCandidates(for: person.id).isEmpty)
        #expect(library.exclude(ids: [candidate.id]))
        let groups = try await library.identificationGroups()
        #expect(!groups.flatMap(\.examples).contains { $0.id == candidate.id || $0.id == replay.id })
        #expect(library.undo())
        let restored = try await library.identificationGroups()
        #expect(restored.flatMap(\.examples).filter { VoiceReviewSelection.sameAudio($0, candidate) }.count == 1)
        #expect(
            Set(
                restored.flatMap(\.evidenceExamples).filter {
                    VoiceReviewSelection.sameAudio($0, candidate)
                }.map(\.id)) == [candidate.id, replay.id])
        let original = try #require(library.examples.first { $0.id == candidate.id })
        #expect(!original.excluded && original.rejectedPersonIDs == [person.id])
        #expect(try await library.reviewCandidates(for: person.id).isEmpty)
    }

    @Test func proposedGroupsJoinMatchingRecordingsAndBatchCountsMatchPlayableQueues() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let first = try sample(root: root)
        let second = try sample(root: root, meeting: first.meetingID, start: 5, vector: [0.999, 0.0447])
        let otherRecording = try sample(root: root)
        #expect(library.upsert([first, second, otherRecording]))
        let groups = try await library.identificationGroups()
        // The shared complete-link policy joins compatible evidence across recordings.
        #expect(groups.count == 1)
        #expect(Set(groups.first?.examples.map(\.id) ?? []) == [first.id, second.id, otherRecording.id])
        let person = UUID()
        let emptyPerson = UUID()
        #expect(library.nameGroup(ids: [first.id, second.id], confirmedExampleID: first.id, personID: person))
        let queues = try await library.reviewCandidates(for: Set([person, emptyPerson]))
        #expect(queues[person]?.isEmpty == true)
        #expect(queues[emptyPerson]?.isEmpty == true)
        #expect(try await library.reviewCandidates(for: person).map(\.id) == queues[person]?.map(\.id))
    }

    @Test func createAndNameIsAtomicAndGuardedUndoRestoresTheWholeAction() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        store.voiceLibrary.didChange = nil
        let meetingID = await store.createMeeting(title: "Naming fixture")
        let sample = try sample(root: root, meeting: meetingID)
        #expect(store.voiceLibrary.upsert([sample]))
        store.canonicalWriteHook = { throw ServiceError("Synthetic write failure") }
        #expect(
            await store.nameVoiceGroup(
                exampleIDs: [sample.id], confirmedExampleID: sample.id,
                personID: nil, newPersonName: "Alex", expectedExamples: [sample]) == nil)
        #expect(store.people.isEmpty)
        #expect(store.voiceLibrary.examples.first?.personID == nil)
        #expect(VoiceLibraryStore(loading: .immediate, directory: root).examples.first?.personID == nil)
        store.canonicalWriteHook = nil
        let id = try #require(
            await store.nameVoiceGroup(
                exampleIDs: [sample.id], confirmedExampleID: sample.id,
                personID: nil, newPersonName: "Alex", expectedExamples: [sample]))
        let token = try #require(store.voiceLibrary.reviewUndoID)
        #expect(store.people.contains { $0.id == id })
        #expect(VoiceLibraryStore(loading: .immediate, directory: root).examples.first?.personID == id)
        #expect(await store.reviewVoiceExamples(.undo, expectedUndoID: token))
        #expect(!store.people.contains { $0.id == id })
        #expect(store.voiceLibrary.examples.first?.personID == nil)
        #expect(store.voiceLibrary.exclude(ids: [sample.id]))
        let stale = try #require(store.voiceLibrary.reviewUndoID)
        #expect(store.voiceLibrary.clear(ids: [sample.id]))
        #expect(await !store.reviewVoiceExamples(.undo, expectedUndoID: stale))
        #expect(store.voiceLibrary.examples.first?.manuallyCleared == true)
    }
    @Test(arguments: [false, true])
    func failedCreationOrUndoPreservesConcurrentOtherPersonEdits(undo: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        store.voiceLibrary.didChange = nil
        let otherID = await store.addPerson(name: "Existing person")
        let meetingID = await store.createMeeting(title: "Naming race fixture")
        let sample = try sample(root: root, meeting: meetingID)
        #expect(store.voiceLibrary.upsert([sample]))
        var createdID: UUID?
        if undo {
            createdID = try #require(
                await store.nameVoiceGroup(
                    exampleIDs: [sample.id], confirmedExampleID: sample.id, personID: nil,
                    newPersonName: "Alex", expectedExamples: [sample]))
        }
        let token = store.voiceLibrary.reviewUndoID
        let gate = VoiceNamingWriteGate(fail: true)
        defer { gate.release() }
        store.canonicalWriteHook = { try gate.enter() }
        let operation = Task { @MainActor in
            if undo { return await store.reviewVoiceExamples(.undo, expectedUndoID: token) }
            return await store.nameVoiceGroupResult(
                exampleIDs: [sample.id], confirmedExampleID: sample.id, personID: nil,
                newPersonName: "Alex", expectedExamples: [sample]) != nil
        }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        var edited = try #require(store.people.first { $0.id == otherID })
        edited.notes = "Concurrent synthetic edit"
        let update = Task { await store.updatePerson(edited) }
        try #require(
            try await waitForMainActorTestCondition(timeout: .seconds(3)) {
                store.people.first { $0.id == otherID }?.notes == edited.notes
            })
        gate.release()
        #expect(await !operation.value)
        await update.value
        #expect(store.people.first { $0.id == otherID }?.notes == edited.notes)
        #expect(store.people.count == (undo ? 2 : 1))
        #expect(store.voiceLibrary.examples.first?.personID == createdID)
        let reopened = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await reopened.libraryMonitor?.stop()
        reopened.libraryMonitor = nil
        #expect(reopened.people.count == (undo ? 2 : 1))
        #expect(reopened.people.first { $0.id == otherID }?.notes == edited.notes)
        #expect(reopened.voiceLibrary.examples.first?.personID == createdID)
    }

    @Test(arguments: [false, true])
    func creationUndoRevalidatesPersonUseWhileAllowingUnrelatedCacheLoads(newUse: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        store.voiceLibrary.didChange = nil
        let meetingID = await store.createMeeting(title: "Named recording")
        let sample = try sample(root: root, meeting: meetingID)
        var meeting = try #require(store.meeting(id: meetingID))
        meeting.audioFiles = ["system.wav"]
        meeting.speakers = [.init(id: sample.speakerID, label: "Speaker 1", track: "system", providerName: "Synthetic")]
        meeting.transcript = [.init(start: 0, end: 4, text: "Synthetic passage", speakerID: sample.speakerID)]
        #expect(await store.updateMeeting(meeting))
        #expect(store.voiceLibrary.upsert([sample]))
        let created = try #require(
            await store.nameVoiceGroup(
                exampleIDs: [sample.id], confirmedExampleID: sample.id, personID: nil,
                newPersonName: "Alex", expectedExamples: [sample]))
        await store.flushVoiceAssignmentRefresh()
        let token = try #require(store.voiceLibrary.reviewUndoID)
        let unrelatedID = await store.createMeeting(title: "Another recording")
        store.clearLoadedMeetingCache()
        if newUse { #expect(await store.ensureMeetingLoaded(id: unrelatedID)) }
        let gate = VoiceNamingWriteGate(fail: false)
        let loadingGate = VoiceNamingWriteGate(fail: false)
        defer { gate.release() }
        defer { loadingGate.release() }
        let reader = store.meetingLoadReader
        store.meetingLoadReader = { id, directory in
            if id == meetingID { try gate.enter() }
            if !newUse && id == unrelatedID { try loadingGate.enter() }
            return try reader(id, directory)
        }
        var loading: Task<Bool, Never>?
        if !newUse {
            // Begin before Undo holds the canonical queue, then publish the
            // cold read while Undo's independent validation read is suspended.
            loading = Task { await store.ensureMeetingLoaded(id: unrelatedID) }
            try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { loadingGate.started })
        }
        let undo = Task { await store.reviewVoiceExamples(.undo, expectedUndoID: token) }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        var update: Task<Bool, Never>?
        if newUse {
            var unrelated = try #require(store.meeting(id: unrelatedID))
            unrelated.personIDs = [created]
            update = Task { await store.updateMeeting(unrelated) }
            try #require(
                try await waitForMainActorTestCondition(timeout: .seconds(3)) {
                    store.meeting(id: unrelatedID)?.personIDs.contains(created) == true
                })
        }
        else {
            loadingGate.release()
            try #require(
                try await waitForMainActorTestCondition(timeout: .seconds(3)) {
                    store.meeting(id: unrelatedID) != nil
                })
        }
        gate.release()
        #expect(await undo.value == !newUse)
        if let update { #expect(await update.value) }
        if let loading { #expect(await loading.value) }
        await store.flushVoiceAssignmentRefresh()
        #expect(store.people.contains { $0.id == created } == newUse)
        #expect(store.voiceLibrary.examples.first?.personID == (newUse ? created : nil))
        #expect(store.voiceLibrary.reviewUndoID == (newUse ? token : nil))
    }

    @Test func namingReceiptReturnsAfterDurableSaveWhileProjectionIsSuspended() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        store.voiceLibrary.didChange = nil
        let person = await store.addPerson(name: "Alex")
        let meeting = await store.createMeeting(title: "Receipt fixture")
        let first = try sample(root: root, meeting: meeting)
        let second = try sample(root: root)
        #expect(store.voiceLibrary.upsert([first, second]))
        store.clearLoadedMeetingCache()
        let gate = VoiceNamingWriteGate(fail: false)
        defer { gate.release() }
        let reader = store.meetingLoadReader
        store.meetingLoadReader = { id, directory in
            if id == meeting { try gate.enter() }
            return try reader(id, directory)
        }
        var acknowledged = false
        let naming = Task {
            let receipt = await store.nameVoiceGroupResult(
                exampleIDs: [first.id], confirmedExampleID: first.id, personID: person,
                newPersonName: nil, expectedExamples: [first])
            acknowledged = true
            return receipt
        }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        // Projection is still suspended. Acknowledgement must depend only on
        // the durable identity save, so the naming dialog can close now.
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { acknowledged })
        let receipt = try #require(await naming.value)
        let namedToken = try #require(store.voiceLibrary.reviewUndoID)
        #expect(receipt.undoID == namedToken)
        #expect(receipt.personID == person)
        #expect(
            VoiceLibraryStore(loading: .immediate, directory: root).examples.first { $0.id == first.id }?.personID
                == person)
        #expect(store.voiceLibrary.exclude(ids: [second.id]))
        let laterToken = try #require(store.voiceLibrary.reviewUndoID)
        #expect(namedToken != laterToken)
        gate.release()
        await store.flushVoiceAssignmentRefresh()
        #expect(store.voiceLibrary.reviewUndoID == laterToken)
    }

    @Test(arguments: [false, true])
    func pendingNamingProjectionUsesTheLatestCorrectionOrUndo(undo: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        store.voiceLibrary.didChange = nil
        let person = await store.addPerson(name: "Alex")
        let replacement = await store.addPerson(name: "Sam")
        let meetingID = await store.createMeeting(title: "Deferred naming fixture")
        let sample = try sample(root: root, meeting: meetingID)
        var meeting = try #require(store.meeting(id: meetingID))
        meeting.audioFiles = ["system.wav"]
        meeting.speakers = [.init(id: sample.speakerID, label: "Speaker 1", track: "system", providerName: "Synthetic")]
        meeting.transcript = [.init(start: 0, end: 4, text: "Synthetic passage", speakerID: sample.speakerID)]
        #expect(await store.updateMeeting(meeting))
        #expect(store.voiceLibrary.upsert([sample]))
        await store.flushVoiceAssignmentRefresh()
        store.clearLoadedMeetingCache()
        let gate = VoiceNamingWriteGate(fail: false)
        defer { gate.release() }
        let reader = store.meetingLoadReader
        store.meetingLoadReader = { id, directory in
            if id == meetingID { try gate.enter() }
            return try reader(id, directory)
        }
        let receipt = try #require(
            await store.nameVoiceGroupResult(
                exampleIDs: [sample.id], confirmedExampleID: sample.id, personID: person,
                newPersonName: nil, expectedExamples: [sample]))
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        if undo {
            #expect(await store.reviewVoiceExamples(.undo, expectedUndoID: receipt.undoID))
        }
        else {
            #expect(await store.reviewVoiceExamples(.confirm(ids: [sample.id], personID: replacement)))
        }
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [meetingID])
        gate.release()
        await store.flushVoiceAssignmentRefresh()
        let saved = try MeetingFolderStorage.read(id: meetingID, directory: root)
        #expect(!saved.personIDs.contains(person))
        #expect(saved.personIDs.contains(replacement) == !undo)
        #expect(store.voiceLibrary.examples.first { $0.id == sample.id }?.personID == (undo ? nil : replacement))
    }

    @Test func oldOptionalGroupProvenanceAndUndoTokensDecodeWithoutInventingHumanDecisions() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = try sample(root: directory)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "namedPersonID")
        let decoded = try JSONDecoder().decode(VoiceExample.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.namedPersonID == nil && decoded.review == .unassigned)
        let undo = VoiceLibraryUndo(examples: [VoiceExampleReviewSnapshot(value)], decisions: [])
        var oldUndo = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(undo)) as? [String: Any])
        oldUndo.removeValue(forKey: "id")
        oldUndo.removeValue(forKey: "createdPerson")
        let decodedUndo = try JSONDecoder().decode(
            VoiceLibraryUndo.self, from: JSONSerialization.data(withJSONObject: oldUndo))
        #expect(decodedUndo.id == nil && decodedUndo.createdPerson == nil)
    }

}

private final class VoiceNamingWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var calls = 0
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls > 0
    }
    func enter() throws {
        lock.lock()
        calls += 1
        let first = calls == 1
        lock.unlock()
        if first {
            semaphore.wait()
            if fail { throw ServiceError("Synthetic write failure") }
        }
    }
    func release() { semaphore.signal() }
}

extension VoiceGroupNamingTests {
    @Test func namingAnAnchorConfirmsItsExactAliasesAndOnlyAssociatesOtherAudio() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let previousPerson = UUID()
        let person = UUID()
        var anchor = try sample(root: root)
        anchor.personID = previousPerson
        anchor.review = .confirmed
        var alias = anchor
        alias.id = UUID()
        alias.groupID = UUID()
        var associatedAlias = anchor
        associatedAlias.id = UUID()
        associatedAlias.personID = nil
        associatedAlias.namedPersonID = previousPerson
        associatedAlias.review = .suggested
        let other = try sample(root: root, meeting: anchor.meetingID, start: 10)
        var conflict = anchor
        conflict.id = UUID()
        conflict.personID = UUID()
        #expect(library.upsert([anchor, alias, associatedAlias, other, conflict]))
        #expect(library.nameGroup(ids: [anchor.id, other.id], confirmedExampleID: anchor.id, personID: person))
        let values = Dictionary(uniqueKeysWithValues: library.examples.map { ($0.id, $0) })
        for id in [anchor.id, alias.id, associatedAlias.id] {
            #expect(values[id]?.personID == person && values[id]?.review == .confirmed)
            #expect(values[id]?.rejectedPersonIDs.contains(previousPerson) == true)
        }
        #expect(values[other.id]?.namedPersonID == person && values[other.id]?.review != .confirmed)
        #expect(values[conflict.id]?.personID == conflict.personID)
        #expect(library.undo())
        #expect(library.examples.first { $0.id == alias.id }?.hasSameReviewEvidence(as: alias) == true)
        #expect(library.examples.first { $0.id == other.id }?.namedPersonID == nil)
    }
}
