import Foundation
import Synchronization
import Testing

@testable import GdayMeetings

@MainActor struct VoiceReviewSnapshotTests {
    @Test func groupingIsSharedAcrossPeopleAndObsoleteWorkCannotPublish() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        var candidate = try sample(root)
        candidate.origin = .discovery
        #expect(library.upsert([candidate]))
        _ = try await library.reviewCandidates(for: UUID())
        #expect(library.reviewGroupingComputationCount == 0)
        _ = try await library.reviewSnapshot(for: [UUID()])
        _ = try await library.reviewSnapshot(for: [UUID()])
        #expect(library.reviewGroupingComputationCount == 1)
        library.invalidateReviewAudio()
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        library.beforeReviewGrouping = {
            continuation.yield(())
            release.wait()
        }
        let pending = Task { try await library.reviewSnapshot(for: []) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        #expect(library.confirm(ids: [candidate.id], personID: UUID()))
        library.beforeReviewGrouping = nil
        release.signal()
        let current = try await pending.value
        #expect(current.unnamedGroups.isEmpty)
        #expect(current.revision == library.reviewEvidenceRevision)
        #expect(library.reviewGroupingComputationCount == 3)
    }

    @Test func cancelledGroupingDoesNotCacheACompletionSentinel() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(library.upsert([try sample(root)]))
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        library.beforeReviewGrouping = {
            continuation.yield(())
            release.wait()
        }
        let pending = Task { try await library.reviewSnapshot(for: []) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        pending.cancel()
        library.beforeReviewGrouping = nil
        release.signal()
        do {
            _ = try await pending.value
            Issue.record("Cancelled grouping returned a presentation.")
        }
        catch {}
        let current = try await library.reviewSnapshot(for: [])
        #expect(current.unnamedGroups.count == 1)
        #expect(library.reviewGroupingComputationCount == 2)
    }

    @Test func automaticRowIdentitySurvivesRemovalOfItsFirstMember() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var first = try sample(root)
        var second = try sample(root)
        first.origin = .discovery
        second.origin = .discovery
        let prior = VoiceIdentificationGroup(id: first.id, examples: [first, second], representativeID: first.id)
        let remaining = VoiceIdentificationGroup(id: second.id, examples: [second], representativeID: second.id)
        #expect(VoiceReviewGroupIdentity.preserving([remaining], previous: [prior]).first?.id == first.id)
    }
    private let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2, normalization: "unitL2")

    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func sample(_ root: URL, groupID: UUID = UUID(), start: Double = 0) throws -> VoiceExample {
        let meeting = UUID()
        let folder = try MeetingFolderLocation.newFolder(id: meeting, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("system.wav")
        try Data("synthetic audio".utf8).write(to: file)
        return VoiceExample(
            meetingID: meeting, speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: VoiceLibraryStore.revision(url: file), start: start, end: start + 4,
            embeddings: [.init(type: type, values: [1, 0])], groupID: groupID)
    }

    @Test func policyChangeReusesEvidenceAndRebuildsSnapshot() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let person = UUID()
        var reference = try sample(root)
        reference.personID = person
        reference.review = .confirmed
        var candidate = try sample(root)
        candidate.embeddings = [.init(type: type, values: [0.79, sqrt(1 - 0.79 * 0.79)])]
        #expect(library.upsert([reference, candidate]))
        let ordinary = try await library.reviewSnapshot(for: [person])
        #expect(ordinary.candidates[person]?.map(\.id) == [candidate.id])
        let stricter = VoiceMatchingPolicy(suggestionThreshold: 0.9, automaticThreshold: 0.95)
        let changed = try await library.reviewSnapshot(for: [person], policy: stricter)
        #expect(changed.candidates[person]?.isEmpty != false)
        #expect(changed.revision == ordinary.revision)
        #expect(try await library.reviewSnapshot(for: [person]).candidates == ordinary.candidates)
    }

    @Test func jobCheckpointDuringSharedReadPreservesQueuesAndEvidenceRevision() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let candidate = try sample(root)
        let person = UUID()
        #expect(library.upsert([candidate]))
        #expect(library.suggest(exampleID: candidate.id, personID: person))
        let revision = library.reviewEvidenceRevision
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        library.beforeReviewRead = {
            #expect(!Thread.isMainThread)
            calls.withLock { $0 += 1 }
            entered.continuation.yield(())
            release.wait()
        }
        let first = Task { try await library.reviewSnapshot(for: [person]) }
        for await _ in entered.stream { break }
        let second = Task { try await library.reviewSnapshot(for: [person]) }
        var job = VoicePreparationJob(
            providerID: UUID(), providerName: "Synthetic provider", type: type,
            discover: false, exampleIDs: [candidate.id])
        job.state = .completed
        job.completedExampleIDs = [candidate.id]
        #expect(library.setJobs([job]))
        #expect(library.reviewEvidenceRevision == revision)
        release.signal()
        let a = try await first.value
        let b = try await second.value
        #expect(a.candidates[person]?.map(\.id) == [candidate.id])
        #expect(b.candidates[person]?.map(\.id) == a.candidates[person]?.map(\.id))
        #expect(try await library.reviewCandidates(for: person).map(\.id) == a.candidates[person]?.map(\.id))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func preparingAutomaticTurnsBecomeQuestionsOnlyAfterRepresentationIsAvailable() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var prepared = try sample(root)
        prepared.origin = .discovery
        prepared.attributionTurn = .init(start: 0, end: 4)
        var pending = prepared
        pending.embeddings = []
        let waiting = VoiceReviewSnapshot.make(
            hydrated: [pending], metadata: [pending], playableIDs: [pending.id], personIDs: [], revision: 1)
        #expect(waiting.unnamedGroups.isEmpty)
        #expect(VoiceReviewSnapshot.selectiveEvidence([pending]).map(\.id) == [pending.id])
        let ready = VoiceReviewSnapshot.make(
            hydrated: [prepared], metadata: [pending], playableIDs: [pending.id], personIDs: [], revision: 2)
        #expect(ready.unnamedGroups.flatMap(\.examples).map(\.id) == [prepared.id])
        pending.manuallyGrouped = true
        let authored = VoiceReviewSnapshot.make(
            hydrated: [pending], metadata: [pending], playableIDs: [pending.id], personIDs: [], revision: 3)
        #expect(authored.unnamedGroups.flatMap(\.examples).map(\.id) == [pending.id])
    }

    @Test func acousticSubgroupsNeverAcquireUnseenConflictingTurnsThroughProviderGroupIDs() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let groupID = UUID()
        var left = try sample(root, groupID: groupID)
        left.origin = .discovery
        left.end = 10
        left.attributionTurn = .init(start: 0, end: 10)
        left.detectedSpeakerID = "cluster-1"
        var hidden = left
        hidden.id = UUID()
        hidden.start = 12
        hidden.end = 16
        hidden.attributionTurn = .init(start: 12, end: 16)
        var right = hidden
        right.id = UUID()
        right.start = 20
        right.end = 24
        right.attributionTurn = .init(start: 20, end: 24)
        right.embeddings = [.init(type: type, values: [0, 1])]
        let examples = [left, hidden, right]
        let metadata = examples.map { original in
            var value = original
            value.embeddings = []
            return value
        }
        let snapshot = VoiceReviewSnapshot.make(
            hydrated: examples, metadata: metadata, playableIDs: Set(examples.map(\.id)),
            personIDs: [], revision: 1)
        #expect(snapshot.unnamedGroups.count == 2)
        let leftGroup = try #require(snapshot.unnamedGroups.first { $0.examples.contains { $0.id == left.id } })
        #expect(leftGroup.evidenceExamples.map(\.id) == [left.id])
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(library.upsert(examples))
        let person = UUID()
        #expect(
            library.nameGroup(
                ids: Set(leftGroup.evidenceExamples.map(\.id)), confirmedExampleID: left.id, personID: person))
        #expect(library.examples.first { $0.id == left.id }?.personID == person)
        #expect(library.examples.first { $0.id == hidden.id }?.namedPersonID == nil)
        #expect(library.examples.first { $0.id == right.id }?.namedPersonID == nil)
        #expect(library.examples.first { $0.id == right.id }?.personID == nil)
    }

    @Test func damagedAuthoredRecordCannotJoinAnAutomaticVoiceWithTheSameProviderGroupID() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let providerGroup = UUID()
        let rejectedPerson = UUID()
        var damaged = try sample(root, groupID: providerGroup)
        damaged.origin = .discovery
        damaged.manuallyGrouped = true
        damaged.review = .rejected
        damaged.rejectedPersonIDs = [rejectedPerson]
        damaged.sourceResolutionIssue = "Synthetic source unavailable"
        var automatic = try sample(root, groupID: providerGroup)
        automatic.origin = .discovery
        automatic.embeddings = [.init(type: type, values: [0, 1])]
        let snapshot = VoiceReviewSnapshot.make(
            hydrated: [damaged, automatic], metadata: [damaged, automatic], playableIDs: [automatic.id],
            personIDs: [], revision: 1)
        let group = try #require(snapshot.unnamedGroups.first)
        #expect(group.evidenceExamples.map(\.id) == [automatic.id])
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(library.upsert([damaged, automatic]))
        let person = UUID()
        #expect(
            library.nameGroup(
                ids: Set(group.evidenceExamples.map(\.id)), confirmedExampleID: automatic.id, personID: person))
        let preserved = try #require(library.examples.first { $0.id == damaged.id })
        #expect(preserved.personID == nil && preserved.namedPersonID == nil)
        #expect(preserved.review == .rejected && preserved.rejectedPersonIDs == [rejectedPerson])
        #expect(library.examples.first { $0.id == automatic.id }?.personID == person)
    }

    @Test func reviewRowsKeepEligibleAudioDisjointAndRetainHiddenNamingEvidence() throws {
        let person = UUID()
        let group = UUID()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var seed = try sample(root)
        seed.personID = person
        seed.review = .confirmed
        var plausible = try sample(root, groupID: group)
        plausible.embeddings = [.init(type: type, values: [0.79, sqrt(1 - 0.79 * 0.79)])]
        var alias = plausible
        alias.id = UUID()
        let unrelated = try sample(root, groupID: group, start: 10)
        var unrelatedHydrated = unrelated
        unrelatedHydrated.embeddings = [.init(type: type, values: [0, 1])]
        var short = try sample(root, groupID: group, start: 20)
        short.end = 20.25
        var invalid = try sample(root, groupID: group, start: 30)
        invalid.embeddings = [.init(type: type, values: [0, 0])]
        let examples = [seed, plausible, alias, unrelatedHydrated, short, invalid].map { original in
            var value = original
            value.manuallyGrouped = value.groupID == group
            return value
        }
        let snapshot = VoiceReviewSnapshot.make(
            hydrated: examples, metadata: examples, playableIDs: Set(examples.map(\.id)),
            personIDs: [person], revision: 4)
        #expect(snapshot.candidates[person]?.count == 1)
        let unnamed = try #require(snapshot.unnamedGroups.first)
        #expect(unnamed.examples.map(\.id) == [unrelated.id])
        #expect(
            Set(unnamed.evidenceExamples.map(\.id)) == [plausible.id, alias.id, unrelated.id, short.id, invalid.id])
        #expect(snapshot.unnamedGroups.flatMap(\.examples).count == 1)
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(library.upsert(examples))
        let namedPerson = UUID()
        #expect(
            library.nameGroup(
                ids: Set(unnamed.evidenceExamples.map(\.id)), confirmedExampleID: unrelated.id, personID: namedPerson))
        #expect(
            library.examples.filter { $0.id == short.id || $0.id == invalid.id }.allSatisfy {
                $0.namedPersonID == namedPerson
            })
        let onlyInvalid = VoiceReviewSnapshot.make(
            hydrated: [short, invalid], metadata: [short, invalid], playableIDs: [short.id, invalid.id],
            personIDs: [], revision: 4)
        #expect(onlyInvalid.unnamedGroups.isEmpty)
    }

    @Test func modelUpdatesCoalesceAndLetAnActiveReadFinish() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let seed = try sample(root)
        var candidate = try sample(root)
        candidate.embeddings = [.init(type: type, values: [0, 1])]
        let person = UUID()
        #expect(library.upsert([seed, candidate]))
        #expect(library.confirm(ids: [seed.id], personID: person))
        #expect(try await library.reviewSnapshot(for: [person]).candidates[person]?.isEmpty == true)
        library.invalidateReviewAudio()
        let revision = library.reviewEvidenceRevision
        let metadataRevision = library.reviewMetadataRevision
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        library.beforeReviewRead = {
            entered.continuation.yield(())
            release.wait()
        }
        let read = Task { try await library.reviewSnapshot(for: [person]) }
        for await _ in entered.stream { break }
        #expect(library.addRepresentation(exampleID: candidate.id, embedding: .init(type: type, values: [1, 0])))
        #expect(
            library.addRepresentation(
                exampleID: candidate.id, embedding: .init(type: type, values: [0.79, sqrt(1 - 0.79 * 0.79)])))
        try await Task.sleep(for: .milliseconds(400))
        #expect(library.reviewEvidenceRevision == revision)
        #expect(library.reviewMetadataRevision == metadataRevision)
        library.beforeReviewRead = nil
        release.signal()
        #expect(try await read.value.candidates[person]?.map(\.id) == [candidate.id])
        for _ in 0..<100 where library.reviewEvidenceRevision == revision {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.reviewEvidenceRevision == revision + 1)
        #expect(library.reviewMetadataRevision == metadataRevision)
        #expect(try await library.reviewSnapshot(for: [person]).candidates[person]?.map(\.id) == [candidate.id])
    }

    @Test func decisionsAndAudioInvalidateImmediatelyDuringModelUpdates() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let candidate = try sample(root)
        let person = UUID()
        #expect(library.upsert([candidate]))
        #expect(library.suggest(exampleID: candidate.id, personID: person))
        #expect(try await library.reviewSnapshot(for: [person]).candidates[person]?.count == 1)
        let revision = library.reviewEvidenceRevision
        let metadataRevision = library.reviewMetadataRevision
        #expect(library.addRepresentation(exampleID: candidate.id, embedding: .init(type: type, values: [0, 1])))
        #expect(library.reviewEvidenceRevision == revision)
        #expect(library.reject(ids: [candidate.id], personID: person))
        #expect(library.reviewEvidenceRevision == revision + 1)
        #expect(library.reviewMetadataRevision == metadataRevision + 1)
        #expect(try await library.reviewSnapshot(for: [person]).candidates[person]?.isEmpty == true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(library.reviewEvidenceRevision == revision + 1)
        let folder = try MeetingFolderLocation.resolve(id: candidate.meetingID, directory: root)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("system.wav"))
        library.invalidateReviewAudio()
        #expect(library.reviewEvidenceRevision == revision + 2)
        #expect(library.reviewMetadataRevision == metadataRevision + 2)
        #expect(try await library.reviewSnapshot(for: []).unnamedGroups.isEmpty)
    }

    @Test func inactiveRepresentationsStayUnopened() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let candidate = try sample(root)
        var ignored = try sample(root)
        ignored.excluded = true
        var cleared = try sample(root)
        cleared.manuallyCleared = true
        #expect(library.upsert([candidate, ignored, cleared]))
        for example in [ignored, cleared] {
            let path = root.appendingPathComponent("voice-library/representations/\(example.id.uuidString).json")
            try Data("invalid inactive representation".utf8).write(to: path)
        }
        let snapshot = try await library.reviewSnapshot(for: [])
        #expect(snapshot.unnamedGroups.flatMap(\.examples).map(\.id) == [candidate.id])
    }

    @Test func refreshRechecksExternalRecordingChangesAndRepresentationsInvalidateCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        var candidate = try sample(root)
        candidate.embeddings = []
        #expect(library.upsert([candidate]))
        let firstRevision = library.reviewEvidenceRevision
        #expect(try await library.reviewSnapshot(for: []).unnamedGroups.count == 1)
        #expect(library.addRepresentation(exampleID: candidate.id, embedding: .init(type: type, values: [1, 0])))
        for _ in 0..<100 where library.reviewEvidenceRevision == firstRevision {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.reviewEvidenceRevision > firstRevision)
        let person = UUID()
        let beforeDelete = library.reviewEvidenceRevision
        #expect(library.removePerson(id: person))
        #expect(library.reviewEvidenceRevision > beforeDelete)
        #expect(try await library.reviewSnapshot(for: [person]).candidates[person] == nil)
        let folder = try MeetingFolderLocation.resolve(id: candidate.meetingID, directory: root)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("system.wav"))
        #expect(try await library.reviewSnapshot(for: [], forceRefresh: true).unnamedGroups.isEmpty)
    }
}
