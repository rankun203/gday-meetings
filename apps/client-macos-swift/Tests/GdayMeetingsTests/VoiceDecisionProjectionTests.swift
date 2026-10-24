import Foundation
import Synchronization
import Testing

@testable import GdayMeetings

@MainActor
struct VoiceDecisionProjectionTests {
    @Test(arguments: ["staleAudio", "missingSpeaker", "validSpeaker"])
    func startupRepairRequiresApplicableEvidence(_ kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Example Person")
        var (meeting, example) = try fixture(directory: directory)
        example.personID = person
        if kind == "staleAudio" {
            meeting.speakers = []
            meeting.transcript[0].speakerID = nil
        }
        try await store.insertImportedMeeting(meeting)
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        if kind == "staleAudio" {
            #expect(library.upsert([example]))
            let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: directory)
            try Data("replacement synthetic audio".utf8).write(to: folder.appendingPathComponent("system.wav"))
        }
        else {
            #expect(
                library.assign(
                    meetingID: meeting.id, speakerID: kind == "validSpeaker" ? meeting.speakers[0].id : UUID(),
                    personID: person))
        }
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
            let shouldRepair = kind == "validSpeaker" && launch == 0
            #expect(reads.withLock { $0 } == (shouldRepair ? 1 : 0))
            #expect(reopened.voiceLibrary.projectionComputationCount == (shouldRepair ? 1 : 0))
            #expect(try reopened.libraryIndex?.count(personID: person) == (kind == "validSpeaker" ? 1 : 0))
        }
    }
    @Test(arguments: ["automatic", "tentative", "confirmed"], [false, true])
    func startupRepairsAssociationMembershipAndAttendance(target: String, alreadyTentative: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Example Person")
        var (meeting, original) = try fixture(directory: directory)
        if alreadyTentative {
            var tentative = original
            tentative.personID = nil
            tentative.review = .suggested
            tentative.transcriptAssociation = .init(
                personID: person, score: 0.6, margin: 0.3, policy: .default, tier: .tentative)
            meeting = VoiceDecisionProjection.apply(
                to: meeting, evidence: [tentative], decisions: [], deletedPeople: [])
        }
        try await store.insertImportedMeeting(meeting)
        let tier: VoiceTranscriptAssociation.Tier = target == "automatic" ? .automatic : .tentative
        var example = original
        example.personID = nil
        example.review = .suggested
        example.transcriptAssociation = .init(
            personID: person, score: tier == .automatic ? 0.9 : 0.6, margin: 0.3, policy: .default, tier: tier)
        if target == "confirmed" {
            example.personID = person
            example.review = .confirmed
            example.transcriptAssociation = nil
        }
        store.voiceLibrary.didChange = nil
        store.voiceLibrary.didChangeProjection = nil
        #expect(store.voiceLibrary.upsert([example]))
        for launch in 0..<2 {
            let reopened = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
            await reopened.libraryMonitor?.stop()
            reopened.libraryMonitor = nil
            let reads = Mutex(0)
            reopened.meetingLoadReader = { id, root in
                reads.withLock { $0 += 1 }
                return try MeetingFolderStorage.read(id: id, directory: root)
            }
            await reopened.flushVoiceAssignmentRefresh()
            let needsRepair = !(alreadyTentative && target == "tentative")
            #expect(reads.withLock { $0 } == (launch == 0 && needsRepair ? 1 : 0))
            #expect(try reopened.libraryIndex?.count(personID: person) == 1)
            let saved = try MeetingFolderStorage.read(id: meeting.id, directory: directory)
            #expect(saved.associatedPersonIDs == [person])
            #expect(
                saved.speakers[0].voiceReviewOrigin?.transcriptAssociationTier == (target == "confirmed" ? nil : tier))
            #expect(saved.personIDs.contains(person) == (target != "tentative"))
        }
    }

    @Test func refreshWaiterCompletesBeforeLaterUnrelatedBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        var fixtures: [(Meeting, VoiceExample)] = []
        for _ in 0..<2 {
            let value = try fixture(directory: directory)
            try await store.insertImportedMeeting(value.0)
            fixtures.append(value)
        }
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        #expect(library.upsert(fixtures.map { $0.1 }))
        await store.flushVoiceAssignmentRefresh()
        library.invalidateDecisionProjections(meetingIDs: Set(fixtures.map { $0.0.id }))
        let calls = Mutex(0)
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        let (entered, continuation) = AsyncStream<Int>.makeStream()
        library.beforeProjectionRead = {
            let call = calls.withLock {
                $0 += 1
                return $0
            }
            continuation.yield(call)
            if call == 1 { first.wait() }
            if call == 2 { second.wait() }
        }
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [fixtures[0].0.id], recomputeSuggestions: false)
        var iterator = entered.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        var earlierFinished = false
        let (waiting, waitingContinuation) = AsyncStream<Void>.makeStream()
        let earlier = Task {
            waitingContinuation.yield(())
            await store.flushVoiceAssignmentRefresh()
            earlierFinished = true
        }
        var waitingIterator = waiting.makeAsyncIterator()
        _ = await waitingIterator.next()
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [fixtures[1].0.id], recomputeSuggestions: false)
        first.signal()
        #expect(await iterator.next() == 2)
        let completed = try await waitForMainActorTestCondition(timeout: .seconds(2)) { earlierFinished }
        second.signal()
        library.beforeProjectionRead = nil
        await earlier.value
        await store.flushVoiceAssignmentRefresh()
        #expect(completed)
    }
    @Test func freshDiscoveryAttendancePersistsAndTracksReassignmentUndoAndUnloadedMeetings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let firstPerson = await store.addPerson(name: "First Person")
        let otherPerson = await store.addPerson(name: "Other Person")
        var examples: [VoiceExample] = []
        var meetingIDs = Set<UUID>()
        for _ in 0..<2 {
            var (meeting, example) = try fixture(directory: directory)
            meeting.speakers = []
            meeting.transcript[0].speakerID = nil
            example.speakerID = UUID()
            example.origin = .discovery
            example.personID = nil
            example.review = .unassigned
            try await store.insertImportedMeeting(meeting)
            examples.append(example)
            meetingIDs.insert(meeting.id)
        }
        let library = store.voiceLibrary
        #expect(library.upsert(examples))
        await store.flushVoiceAssignmentRefresh()
        #expect(try store.libraryIndex?.count(personID: firstPerson) == 0)
        let anchor = examples[0]
        let receipt = try #require(
            await store.nameVoiceGroupResult(
                exampleIDs: [anchor.id], confirmedExampleID: anchor.id,
                personID: firstPerson, newPersonName: nil, expectedExamples: [anchor]))
        #expect(receipt.personID == firstPerson)
        await store.flushVoiceAssignmentRefresh()
        #expect(try store.libraryIndex?.count(personID: firstPerson) == 1)
        // The second meeting is outside the currently loaded detail page.
        store.meetings.removeAll { $0.id == examples[1].meetingID }
        #expect(await store.reviewVoiceExamples(.confirm(ids: [examples[1].id], personID: firstPerson)))
        await store.flushVoiceAssignmentRefresh()
        #expect(try store.libraryIndex?.count(personID: firstPerson) == 2)
        for id in meetingIDs {
            let saved = try MeetingFolderStorage.read(id: id, directory: directory)
            #expect(saved.personIDs == [firstPerson])
            #expect(saved.transcript[0].speakerID == nil)
            #expect(saved.speakers.count == 1)
            #expect(library.applyingDecisions(to: saved) == saved)
        }
        #expect(await store.reviewVoiceExamples(.confirm(ids: [anchor.id], personID: otherPerson)))
        await store.flushVoiceAssignmentRefresh()
        #expect(try store.libraryIndex?.count(personID: firstPerson) == 1)
        #expect(try store.libraryIndex?.count(personID: otherPerson) == 1)
        #expect(await store.reviewVoiceExamples(.undo))
        await store.flushVoiceAssignmentRefresh()
        #expect(try store.libraryIndex?.count(personID: firstPerson) == 2)
        #expect(try store.libraryIndex?.count(personID: otherPerson) == 0)
        #expect(await store.reviewVoiceExamples(.clear(ids: [anchor.id])))
        await store.flushVoiceAssignmentRefresh()
        let cleared = try MeetingFolderStorage.read(id: anchor.meetingID, directory: directory)
        #expect(cleared.personIDs.isEmpty)
        #expect(cleared.speakers.isEmpty)
        // Reopening reconciles retained reviewed evidence into the disposable
        // index independently of the currently loaded meeting page.
        let reopened = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await reopened.libraryMonitor?.stop()
        reopened.libraryMonitor = nil
        #expect(reopened.voiceLibrary.isLoaded)
        await reopened.flushVoiceAssignmentRefresh()
        #expect(try reopened.libraryIndex?.count(personID: firstPerson) == 1)
        #expect(try reopened.libraryIndex?.count(personID: otherPerson) == 0)
        #expect(reopened.voiceLibrary.projectionComputationCount == 0)
        // A prior build could save the review while omitting its meeting link.
        // Only that inconsistent entry should require hydration and projection.
        let remaining = examples[1].meetingID
        var missingLink = try MeetingFolderStorage.read(id: remaining, directory: directory)
        missingLink.speakers = []
        missingLink.personIDs = []
        try MeetingFolderStorage.write(missingLink, directory: directory)
        try reopened.libraryIndex?.upsert(MeetingListEntry(missingLink))
        let repair = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await repair.libraryMonitor?.stop()
        repair.libraryMonitor = nil
        #expect(repair.voiceLibrary.isLoaded)
        await repair.flushVoiceAssignmentRefresh()
        #expect(try repair.libraryIndex?.count(personID: firstPerson) == 1)
        #expect(repair.voiceLibrary.projectionComputationCount == 1)
    }

    @Test func standaloneAttendanceRequiresCurrentUnambiguousConfirmedEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var (meeting, example) = try fixture(directory: directory)
        meeting.speakers = []
        meeting.transcript[0].speakerID = nil
        #expect(library.upsert([example]))
        let assigned = try #require(await library.projectedDecisions(to: meeting))
        #expect(assigned.personIDs == [example.personID!])
        var conflicting = example
        conflicting.id = UUID()
        conflicting.personID = UUID()
        #expect(library.upsert([conflicting]))
        let disputed = try #require(await library.projectedDecisions(to: assigned))
        #expect(disputed.personIDs.isEmpty)
        #expect(disputed.speakers.isEmpty)
        #expect(library.exclude(ids: [conflicting.id]))
        let restored = try #require(await library.projectedDecisions(to: disputed))
        #expect(restored.personIDs == [example.personID!])
        let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: directory)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("changed synthetic audio".utf8).write(to: audio)
        library.invalidateDecisionProjections(paths: [audio], root: directory, rebuild: false)
        let stale = try #require(await library.projectedDecisions(to: restored))
        #expect(stale.personIDs.isEmpty)
        #expect(stale.speakers.isEmpty)
        example.review = .suggested
        example.audioRevision = VoiceLibraryStore.revision(url: audio)
        #expect(library.upsert([example]))
        #expect(await library.projectedDecisions(to: stale) == stale)
    }

    @Test(arguments: [VoiceTranscriptAssociation.Tier.automatic, .tentative])
    func machineAssociationLabelsEveryDetectedSpeakerRowAndPreservesAcousticUncertainty(
        tier: VoiceTranscriptAssociation.Tier
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        let person = try #require(example.personID)
        example.personID = nil
        example.review = .suggested
        example.transcriptAssociation = .init(
            personID: person, score: tier == .automatic ? 0.9 : 0.6, margin: 0.3, policy: .default, tier: tier)
        let originalSpeaker = meeting.speakers[0].id
        meeting.transcript[0].associationUncertain = true
        meeting.transcript.append(.init(start: 10, end: 12, text: "Another passage", speakerID: originalSpeaker))
        meeting.transcript.append(.init(start: 13, end: 14, speaker: "sys", text: "Unassigned passage"))
        let result = VoiceDecisionProjection.apply(to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        #expect(result.speakers.first { $0.id == originalSpeaker }?.personID == person)
        #expect(result.speakers.first { $0.id == originalSpeaker }?.manuallyAssigned == false)
        #expect(result.transcript[0].associationUncertain == true)
        #expect(result.speakers[0].voiceReviewOrigin?.transcriptAssociationTier == tier)
        #expect(result.transcript[1].associationUncertain == nil)
        #expect(result.transcript[2] == meeting.transcript[2])
        #expect(result.personIDs.contains(person) == (tier == .automatic))
        #expect(result.associatedPersonIDs == [person])
        #expect(
            VoiceDecisionProjection.apply(to: result, evidence: [example], decisions: [], deletedPeople: []) == result)
        let restored = VoiceDecisionProjection.apply(to: result, evidence: [], decisions: [], deletedPeople: [])
        #expect(restored.speakers == meeting.speakers)
        #expect(restored.transcript == meeting.transcript)
        #expect(restored.associatedPersonIDs.isEmpty)
    }

    @Test func machineAssociationRespectsPolicyChangesManualAssignmentAndRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        let person = try #require(example.personID)
        example.personID = nil
        example.review = .suggested
        example.transcriptAssociation = .init(personID: person, score: 0.9, margin: 0.3, policy: .default)
        let projected = VoiceDecisionProjection.apply(
            to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        var policy = VoiceMatchingPolicy.default
        policy.automaticThreshold = 0.95
        let stale = VoiceDecisionProjection.apply(
            to: projected, evidence: [example], decisions: [], deletedPeople: [], policy: policy)
        #expect(stale.speakers[0].personID == nil)
        example.rejectedPersonIDs = [person]
        #expect(
            VoiceDecisionProjection.apply(to: projected, evidence: [example], decisions: [], deletedPeople: []).speakers
                .allSatisfy { $0.personID == nil })
        example.rejectedPersonIDs = []
        let manual = UUID()
        meeting.speakers[0].personID = manual
        meeting.speakers[0].manuallyAssigned = true
        #expect(
            VoiceDecisionProjection.apply(to: meeting, evidence: [example], decisions: [], deletedPeople: []).speakers[
                0
            ].personID == manual)
    }

    @Test func discoveryScopeMapsOnlyOneExistingDetectedSpeaker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        let person = try #require(example.personID)
        example.speakerID = UUID()
        example.origin = .discovery
        example.detectedSpeakerConfiguration = .community
        meeting.speakerLabelSource = .init(resultID: UUID(), providerName: "Synthetic", generatedAt: Date())
        example.detectedSpeakerResultID = meeting.speakerLabelSource?.resultID
        example.detectedSpeakerSpans = [.init(start: 0, end: 2), .init(start: 10, end: 12)]
        meeting.transcript.append(.init(start: 10, end: 12, text: "Later passage", speakerID: meeting.speakers[0].id))
        let projected = VoiceDecisionProjection.apply(
            to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        #expect(projected.speakers.first { $0.id == meeting.speakers[0].id }?.personID == person)
        let other = MeetingSpeaker(label: "Speaker 2", track: "system", providerName: "Synthetic")
        meeting.speakers.append(other)
        meeting.transcript.append(.init(start: 10, end: 11, text: "Conflicting voice", speakerID: other.id))
        let ambiguous = VoiceDecisionProjection.apply(
            to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        #expect(ambiguous.speakers.first { $0.id == meeting.speakers[0].id }?.personID == nil)
    }

    @Test func clearPreventsAnotherExcerptFromRelabelingSameDetectedSpeaker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, original) = try fixture(directory: directory)
        let person = try #require(original.personID)
        var candidate = original
        candidate.id = UUID()
        candidate.personID = nil
        candidate.review = .suggested
        candidate.transcriptAssociation = .init(personID: person, score: 0.9, margin: 0.3, policy: .default)
        var cleared = original
        cleared.personID = nil
        cleared.review = .unassigned
        cleared.manuallyCleared = true
        let result = VoiceDecisionProjection.apply(
            to: meeting, evidence: [candidate, cleared], decisions: [], deletedPeople: [])
        #expect(result.speakers.allSatisfy { $0.personID == nil })
    }

    @Test func discoverySupportCannotIdentifyAnOverlappingLongTranscriptRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        example.speakerID = UUID()
        example.origin = .discovery
        example.detectedSpeakerConfiguration = .community
        example.detectedSpeakerSpans = [.init(start: 1, end: 2)]
        meeting.transcript[0].end = 20
        let result = VoiceDecisionProjection.apply(to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        #expect(result.speakers.first { $0.id == meeting.speakers[0].id }?.personID == nil)
        #expect(result.transcript == meeting.transcript)
    }

    @Test func machineAssociationReviewAndUndoRetainSeparateState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (meeting, original) = try fixture(directory: directory)
        let person = try #require(original.personID)
        var example = original
        example.personID = nil
        example.review = .suggested
        example.transcriptAssociation = .init(personID: person, score: 0.9, margin: 0.3, policy: .default)
        #expect(library.upsert([example]))
        #expect(library.applyingDecisions(to: meeting).speakers[0].personID == person)
        #expect(library.examples[0].personID == nil)
        #expect(library.reject(ids: [example.id], personID: person))
        #expect(library.examples[0].transcriptAssociation == nil)
        #expect(library.applyingDecisions(to: meeting).speakers[0].personID == nil)
        #expect(library.undo())
        #expect(library.examples[0].transcriptAssociation == example.transcriptAssociation)
        let reopened = VoiceLibraryStore(loading: .immediate, directory: directory)
        #expect(reopened.examples[0].transcriptAssociation == example.transcriptAssociation)
        #expect(reopened.applyingDecisions(to: meeting).speakers[0].personID == person)
        let token = try #require(await reopened.decisionProjection(to: meeting)).token
        var changedPolicy = VoiceMatchingPolicy.default
        changedPolicy.automaticThreshold = 0.95
        reopened.invalidateMatchingPolicy(changedPolicy)
        #expect(!reopened.isCurrentDecisionProjection(token))
        #expect(reopened.applyingDecisions(to: meeting).speakers[0].personID == nil)
    }

    @Test func workerPublicationProjectsAndPersistsAllRowsWithoutEnrollingCandidate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Example Person")
        let type = EmbeddingType(
            modelID: "synthetic", revision: "one", compatibilityVersion: "one", dimension: 2,
            normalization: "unitL2")
        var (referenceMeeting, reference) = try fixture(directory: directory)
        referenceMeeting.title = "Reference recording"
        reference.personID = person
        reference.embeddings = [.init(type: type, values: [1, 0])]
        var (candidateMeeting, candidate) = try fixture(directory: directory)
        candidateMeeting.title = "New recording"
        candidateMeeting.transcript.append(
            .init(start: 10, end: 12, text: "Another passage", speakerID: candidateMeeting.speakers[0].id))
        candidate.personID = nil
        candidate.review = .unassigned
        candidate.embeddings = [.init(type: type, values: [0.81, sqrt(1 - 0.81 * 0.81)])]
        try await store.insertImportedMeeting(referenceMeeting)
        try await store.insertImportedMeeting(candidateMeeting)
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        await store.flushVoiceAssignmentRefresh()
        #expect(library.upsert([reference, candidate]))
        await store.refreshVoiceAssignments(meetingIDs: [referenceMeeting.id], recomputeSuggestions: false)
        var publications = Set<UUID>()
        library.didChangeProjection = { ids in
            publications.formUnion(ids)
            store.scheduleVoiceAssignmentRefresh(meetingIDs: ids, recomputeSuggestions: false)
        }
        try await library.suggestReviewedPeopleResult(from: store.people)
        await store.flushVoiceAssignmentRefresh()
        #expect(publications == [candidateMeeting.id])
        let saved = try MeetingFolderStorage.read(id: candidateMeeting.id, directory: directory)
        #expect(saved.personIDs.contains(person))
        #expect(saved.speakers.first { $0.id == candidate.speakerID }?.personID == person)
        #expect(
            saved.speakers.first { $0.id == candidate.speakerID }?.voiceReviewOrigin?.transcriptAssociationTier
                == .automatic)
        #expect(saved.transcript.allSatisfy { $0.speakerID == candidate.speakerID })
        let retained = try #require(library.examples.first { $0.id == candidate.id })
        #expect(retained.personID == nil && retained.review != .confirmed)
        #expect(retained.transcriptAssociation?.personID == person)
        let reopened = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await reopened.libraryMonitor?.stop()
        reopened.libraryMonitor = nil
        #expect(reopened.voiceLibrary.isLoaded)
        await reopened.flushVoiceAssignmentRefresh()
        #expect(try reopened.libraryIndex?.count(personID: person) == 2)
        #expect(await reopened.ensureMeetingLoaded(id: candidateMeeting.id))
        let restored = try #require(reopened.meeting(id: candidateMeeting.id))
        #expect(restored.speakers.first { $0.id == candidate.speakerID }?.personID == person)
    }

    @Test func confirmedExcerptPreservesAcousticUncertaintyAndSpeakerOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        let other = MeetingSpeaker(label: "Speaker 2", track: "system", providerName: "Synthetic")
        meeting.speakers.append(other)
        meeting.transcript[0].associationUncertain = true
        meeting.transcript.append(.init(start: 10, end: 12, text: "Certain passage", speakerID: example.speakerID))
        meeting.transcript.append(.init(start: 15, end: 17, text: "Other voice", speakerID: other.id))
        example.review = .confirmed
        let projected = VoiceDecisionProjection.apply(
            to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        #expect(projected.speakers.map(\.id) == meeting.speakers.map(\.id))
        let speaker = try #require(projected.speakers.first { $0.id == example.speakerID })
        #expect(speaker.manuallyAssigned == false)
        #expect(!projected.transcript[0].allowsPersonAssociation(from: speaker))
        #expect(projected.transcript[1].allowsPersonAssociation(from: speaker))
        #expect(
            VoiceDecisionProjection.apply(to: projected, evidence: [example], decisions: [], deletedPeople: [])
                == projected)
    }

    @Test func weakestMachineTierWinsAndStaysOutOfAttendance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, original) = try fixture(directory: directory)
        let person = try #require(original.personID)
        var strong = original
        strong.personID = nil
        strong.review = .suggested
        strong.transcriptAssociation = .init(personID: person, score: 0.9, margin: 0.3, policy: .default)
        var weak = strong
        weak.id = UUID()
        weak.transcriptAssociation = .init(
            personID: person, score: 0.6, margin: 0.3, policy: .default, tier: .tentative)
        for evidence in [[strong, weak], [weak, strong]] {
            let projected = VoiceDecisionProjection.apply(
                to: meeting, evidence: evidence, decisions: [], deletedPeople: [])
            #expect(projected.speakers[0].voiceReviewOrigin?.transcriptAssociationTier == .tentative)
            #expect(projected.speakers[0].confidence == 0.6)
            #expect(!projected.speakers[0].confirmed)
            #expect(projected.personIDs.isEmpty)
        }
    }

    @Test func retainedSpeakerIdentitySurvivesSourceGenerationRefresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        let person = try #require(example.personID)
        example.personID = nil
        example.review = .suggested
        example.origin = .savedSpeaker
        example.detectedSpeakerResultID = UUID()
        example.detectedSpeakerSpans = [.init(start: 0, end: 2)]
        example.transcriptAssociation = .init(personID: person, score: 0.9, margin: 0.3, policy: .default)
        meeting.speakerLabelSource = .init(
            resultID: example.detectedSpeakerResultID!, providerName: "Synthetic", generatedAt: Date())
        #expect(
            VoiceDecisionProjection.apply(to: meeting, evidence: [example], decisions: [], deletedPeople: []).speakers[
                0
            ].personID == person)
        meeting.speakerLabelSource?.resultID = UUID()
        let retained = VoiceDecisionProjection.apply(to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        #expect(retained.speakers[0].personID == person)
        meeting.speakers[0].id = UUID()
        meeting.transcript[0].speakerID = meeting.speakers[0].id
        let changed = VoiceDecisionProjection.apply(to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        #expect(changed.speakers[0].personID == nil)
        #expect(changed.personIDs.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func transcriptCorrectionUsesSpeakerDecisionAndUndoRestoresMachineTier(remove: Bool, confirmedReference: Bool)
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let first = await store.addPerson(name: "Example Person A")
        let second = await store.addPerson(name: "Example Person B")
        let (meeting, original) = try fixture(directory: directory)
        try await store.insertImportedMeeting(meeting)
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        await store.flushVoiceAssignmentRefresh()
        var example = original
        example.personID = confirmedReference ? first : nil
        example.review = confirmedReference ? .confirmed : .suggested
        example.transcriptAssociation =
            confirmedReference
            ? nil
            : .init(
                personID: first, score: 0.6, margin: 0.3, policy: .default, tier: .tentative)
        #expect(library.upsert([example]))
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        #expect(
            await store.assignSpeaker(
                meetingID: meeting.id, speakerID: example.speakerID, personID: remove ? nil : second))
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        let corrected = try #require(store.meeting(id: meeting.id))
        #expect(
            library.decisions.contains { $0.speakerID == example.speakerID && $0.personID == (remove ? nil : second) })
        #expect(corrected.speakers[0].personID == (remove ? nil : second))
        #expect(corrected.speakers[0].voiceReviewOrigin?.transcriptAssociationTier == nil)
        #expect(corrected.speakers[0].manuallyAssigned == true)
        #expect(library.examples[0].review == example.review)
        #expect(library.examples[0].personID == example.personID)
        #expect(store.people.allSatisfy { $0.voiceSamples.isEmpty })
        #expect(library.undo())
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        let restored = try #require(store.meeting(id: meeting.id))
        #expect(restored.speakers[0].personID == first)
        #expect(
            restored.speakers[0].voiceReviewOrigin?.transcriptAssociationTier == (confirmedReference ? nil : .tentative)
        )
        #expect(restored.speakers[0].manuallyAssigned == false)
    }

    @Test func cachedDiscoveryScopeMapsAcrossIndependentAnalysisIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        let person = try #require(example.personID)
        meeting.transcript.append(.init(start: 10, end: 12, text: "Later passage", speakerID: meeting.speakers[0].id))
        meeting.speakerLabelSource = .init(resultID: UUID(), providerName: "Synthetic", generatedAt: Date())
        var discoverySpeaker = MeetingSpeaker(label: "voice_a", track: "track0", providerName: "Synthetic")
        discoverySpeaker.voiceSampleRange = example.range
        discoverySpeaker.voiceSampleRevision = example.audioRevision
        let analysis = LocalDiarizationResult(
            modelRevision: "synthetic-v1",
            ranges: [
                .init(track: "track0", label: "voice_a", start: 0, end: 2),
                .init(track: "track0", label: "voice_a", start: 10, end: 12),
            ], speakers: [discoverySpeaker])
        let input = VoiceDiscoveryInput(
            meetingID: meeting.id, audioFiles: meeting.audioFiles,
            audioRevisions: ["system.wav": example.audioRevision!])
        let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: directory)
        let cache = VoiceDiscoveryCache()
        try await cache.save(analysis, input: input, configuration: .community, directory: folder)
        let cached = try #require(try await cache.read(input: input, configuration: .community, directory: folder))
        #expect(cached.id != meeting.speakerLabelSource?.resultID)
        example.personID = nil
        example.review = .suggested
        example.origin = .discovery
        example.speakerID = cached.speakers[0].id
        example.detectedSpeakerID = VoiceDetectedSpeakerScope.identity(speaker: cached.speakers[0], analysis: cached)
        example.detectedSpeakerSpans = VoiceDetectedSpeakerScope.spans(speaker: cached.speakers[0], analysis: cached)
        example.detectedSpeakerResultID = cached.id
        example.detectedSpeakerConfiguration = .community
        example.transcriptAssociation = .init(personID: person, score: 0.9, margin: 0.3, policy: .default)
        let evidence = VoiceDecisionProjection.currentEvidence([example], directory: directory)
        let projected = VoiceDecisionProjection.apply(to: meeting, evidence: evidence, decisions: [], deletedPeople: [])
        #expect(projected.speakers[0].personID == person)
        #expect(projected.transcript.allSatisfy { $0.speakerID == meeting.speakers[0].id })
        var uncertain = meeting
        var uncertainRow = TranscriptSegment(
            start: 20, end: 22, text: "Acoustically uncertain passage", speakerID: meeting.speakers[0].id)
        uncertainRow.associationUncertain = true
        uncertain.transcript.append(uncertainRow)
        let withUncertainty = VoiceDecisionProjection.apply(
            to: uncertain, evidence: evidence, decisions: [], deletedPeople: [])
        #expect(withUncertainty.speakers[0].personID == person)
        #expect(!withUncertainty.transcript.last!.allowsPersonAssociation(from: withUncertainty.speakers[0]))
        var merged = meeting
        merged.transcript.append(
            .init(start: 20, end: 22, text: "Uncovered merged voice", speakerID: meeting.speakers[0].id))
        #expect(
            VoiceDecisionProjection.apply(to: merged, evidence: evidence, decisions: [], deletedPeople: []).speakers[0]
                .personID == nil)
        var outdated = example
        outdated.detectedSpeakerConfiguration?.pipeline = "different-config"
        #expect(
            VoiceDecisionProjection.apply(to: meeting, evidence: [outdated], decisions: [], deletedPeople: []).speakers[
                0
            ].personID == nil)
    }

    @Test(arguments: [false, true])
    func tentativeSpeakerCannotBlockIndependentConfirmedAttendance(coversRow: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, original) = try fixture(directory: directory)
        let person = try #require(original.personID)
        var tentative = original
        tentative.personID = nil
        tentative.review = .suggested
        tentative.transcriptAssociation = .init(
            personID: person, score: 0.6, margin: 0.3, policy: .default, tier: .tentative)
        var confirmed = original
        confirmed.id = UUID()
        confirmed.speakerID = UUID()
        confirmed.start = coversRow ? 0 : 20
        confirmed.end = coversRow ? 2 : 22
        let projected = VoiceDecisionProjection.apply(
            to: meeting, evidence: [tentative, confirmed], decisions: [], deletedPeople: [])
        #expect(projected.personIDs.contains(person))
        #expect(projected.speakers.contains { $0.attendancePersonID == person })
        #expect(
            VoiceDecisionProjection.apply(
                to: projected, evidence: [tentative, confirmed], decisions: [], deletedPeople: []) == projected)
        if coversRow {
            let rowSpeaker = projected.speakers.first { $0.id == projected.transcript[0].speakerID }
            #expect(rowSpeaker?.voiceReviewOrigin?.transcriptAssociationTier == nil)
        }
    }

    @Test func tentativeSharedNamesMarkUncertaintyAndIncludeParticipantNotes() {
        var person = Person(name: "Example Person")
        person.notes = "Private reference notes"
        var meeting = Meeting(title: "Synthetic recording")
        var speaker = MeetingSpeaker(label: "sys_01", track: "system", providerName: "Synthetic", personID: person.id)
        speaker.voiceReviewOrigin = .init(speakerID: speaker.id, transcriptAssociationTier: .tentative)
        meeting.speakers = [speaker]
        meeting.transcript = [
            .init(start: 0, end: 2, speaker: "sys_01", text: "Synthetic passage", speakerID: speaker.id)
        ]
        #expect(meeting.speakerName(for: meeting.transcript[0], people: [person]) == "Example Person (Tentative)")
        let messages = SummaryPrompt.messages(
            provider: ServiceProvider(kind: .openAICompatible), meeting: meeting, people: [person])
        #expect(messages.contains { $0.content.contains("Example Person ?") })
        #expect(messages.contains { $0.content.contains(person.notes) })
    }

    @Test func explicitPassageCorrectionOutranksIndependentReferenceReview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (meeting, reference) = try fixture(directory: directory)
        let referencePerson = try #require(reference.personID)
        let passagePerson = UUID()
        let corrected = try #require(
            TranscriptPassageAssignment.applying(
                to: meeting, rowID: meeting.transcript[0].id, personID: passagePerson,
                people: [referencePerson, passagePerson]))
        let projected = VoiceDecisionProjection.apply(
            to: corrected, evidence: [reference], decisions: [], deletedPeople: [])
        let passage = try #require(projected.speakers.first { $0.id == projected.transcript[0].speakerID })
        #expect(passage.personID == passagePerson)
        #expect(passage.passageAssignmentOrigin != nil)
        #expect(reference.personID == referencePerson)
    }

    @Test(arguments: [VoiceTranscriptAssociation.Tier.automatic, .tentative])
    func aNewDiarizationCanRelabelMachineAttributedRows(tier: VoiceTranscriptAssociation.Tier) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var (meeting, example) = try fixture(directory: directory)
        let person = try #require(example.personID)
        meeting.speakerLabelSource = .init(resultID: UUID(), providerName: "Synthetic", generatedAt: Date())
        example.origin = .savedSpeaker
        example.detectedSpeakerResultID = meeting.speakerLabelSource?.resultID
        example.personID = nil
        example.review = .suggested
        example.transcriptAssociation = .init(
            personID: person, score: tier == .automatic ? 0.9 : 0.6, margin: 0.3, policy: .default, tier: tier)
        #expect(library.upsert([example]))
        let first = library.applyingDecisions(to: meeting)
        let replacement = MeetingSpeaker(label: "new_voice", track: "track0", providerName: "Synthetic")
        let analysis = LocalDiarizationResult(
            modelRevision: "synthetic-v2",
            ranges: [
                .init(track: "track0", label: "new_voice", start: 0, end: 2)
            ], speakers: [replacement])
        var rescanned = LocalDiarizationAssignment.applying(analysis, to: first, fileCount: 1)
        rescanned.speakerLabelSource = .init(
            resultID: analysis.id, providerName: "Synthetic", generatedAt: analysis.generatedAt)
        let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: directory)
        #expect(library.ingest(meeting: rescanned, directory: folder))
        #expect(rescanned.transcript[0].speakerID == replacement.id)
        #expect(rescanned.transcript[0].speakerID != example.speakerID)
        let projected = library.applyingDecisions(to: rescanned)
        #expect(projected.speakers.first { $0.id == replacement.id }?.personID == nil)
        #expect(projected.transcript.allSatisfy { $0.speakerID == replacement.id })
    }

    @Test func tentativeNamePreservesAnIndependentImportedAttendee() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        let person = try #require(example.personID)
        meeting.personIDs = [person]
        example.personID = nil
        example.review = .suggested
        example.transcriptAssociation = .init(
            personID: person, score: 0.6, margin: 0.3, policy: .default, tier: .tentative)
        let projected = VoiceDecisionProjection.apply(
            to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        #expect(projected.personIDs == [person])
        #expect(projected.speakers[0].attendancePersonID == nil)
        let corrected = VoiceDecisionProjection.apply(
            to: projected, evidence: [], decisions: [], deletedPeople: [])
        #expect(corrected.personIDs == [person])
        #expect(corrected.associatedPersonIDs == [person])
    }

    @Test(arguments: [false, true])
    func independentTurnsAttributeFullSupportWithoutNamingClusterOrUnknownSpeech(discovery: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, sample) = try fixture(directory: directory)
        meeting.speakers[0].independentTurnAttribution = discovery ? nil : true
        let clusterID = meeting.speakers[0].id
        meeting.transcript = (0..<6).map {
            TranscriptSegment(start: Double($0), end: Double($0 + 1), text: "Part \($0)", speakerID: clusterID)
        }
        meeting.transcript[4].associationUncertain = true
        let firstPerson = UUID()
        let secondPerson = UUID()
        sample.personID = nil
        sample.review = .suggested
        sample.end = 0.5
        sample.attributionTurn = .init(start: 0, end: 2)
        sample.transcriptAssociation = .init(personID: firstPerson, score: 0.9, margin: 0.3, policy: .default)
        var other = sample
        other.id = UUID()
        other.start = 3
        other.end = 3.5
        other.attributionTurn = .init(start: 3, end: 5)
        other.transcriptAssociation = .init(
            personID: secondPerson, score: 0.6, margin: 0.3, policy: .default, tier: .tentative)
        // A retained cluster excerpt cannot extend its identity across independent turns.
        var old = sample
        old.id = UUID()
        old.attributionTurn = nil
        old.end = 6
        if discovery {
            sample.speakerID = UUID()
            sample.origin = .discovery
            sample.detectedSpeakerConfiguration = .community
            other.speakerID = UUID()
            other.origin = .discovery
            other.detectedSpeakerConfiguration = .community
        }
        var legacyConfirmed = old
        legacyConfirmed.id = UUID()
        legacyConfirmed.end = 0.5
        legacyConfirmed.personID = UUID()
        legacyConfirmed.review = .confirmed
        legacyConfirmed.transcriptAssociation = nil
        let evidence = [sample, other, old, legacyConfirmed]
        let projected = VoiceDecisionProjection.apply(to: meeting, evidence: evidence, decisions: [], deletedPeople: [])
        func person(_ index: Int) -> UUID? {
            projected.speakers.first { $0.id == projected.transcript[index].speakerID }?.personID
        }
        #expect((0..<6).map(person) == [firstPerson, firstPerson, nil, secondPerson, nil, nil])
        #expect(projected.transcript[0].speakerID == projected.transcript[1].speakerID)
        let tentative = projected.speakers.first { $0.id == projected.transcript[3].speakerID }
        #expect(tentative?.voiceReviewOrigin?.transcriptAssociationTier == .tentative)
        #expect(!projected.personIDs.contains(secondPerson))
        #expect(
            VoiceDecisionProjection.apply(to: projected, evidence: evidence, decisions: [], deletedPeople: [])
                == projected)
        let withdrawn = VoiceDecisionProjection.apply(to: projected, evidence: [], decisions: [], deletedPeople: [])
        #expect(withdrawn.transcript.map(\.speakerID) == Array(repeating: Optional(clusterID), count: 6))
        #expect(withdrawn.speakers.allSatisfy { $0.personID == nil })
        let override = VoiceSpeakerDecision(
            meetingID: meeting.id, speakerID: projected.transcript[0].speakerID!, personID: secondPerson)
        let corrected = VoiceDecisionProjection.apply(
            to: projected, evidence: evidence, decisions: [override], deletedPeople: [])
        #expect(corrected.speakers.filter { $0.id == clusterID }.first?.personID == secondPerson)
        #expect(corrected.transcript.allSatisfy { $0.speakerID == clusterID })
        let undone = VoiceDecisionProjection.apply(to: corrected, evidence: evidence, decisions: [], deletedPeople: [])
        #expect(undone.transcript.map(\.speakerID) == projected.transcript.map(\.speakerID))
    }

    @Test func wholeSpeakerCorrectionFromTurnNameAndUndoRetainIndependentMatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let firstPerson = await store.addPerson(name: "Example Person A")
        let secondPerson = await store.addPerson(name: "Example Person B")
        var (meeting, first) = try fixture(directory: directory)
        let cluster = meeting.speakers[0].id
        meeting.speakers[0].independentTurnAttribution = true
        meeting.transcript = [
            .init(start: 0, end: 1, text: "First turn", speakerID: cluster),
            .init(start: 1, end: 2, text: "Second turn", speakerID: cluster),
        ]
        try await store.insertImportedMeeting(meeting)
        await store.flushVoiceAssignmentRefresh()
        store.voiceLibrary.didChange = nil
        store.voiceLibrary.didChangeProjection = nil
        first.personID = nil
        first.review = .suggested
        first.end = 0.5
        first.attributionTurn = .init(start: 0, end: 1)
        first.transcriptAssociation = .init(personID: firstPerson, score: 0.9, margin: 0.3, policy: .default)
        var second = first
        second.id = UUID()
        second.start = 1
        second.end = 1.5
        second.attributionTurn = .init(start: 1, end: 2)
        second.transcriptAssociation?.personID = secondPerson
        #expect(store.voiceLibrary.upsert([first, second]))
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        let projected = try #require(store.meeting(id: meeting.id))
        let target = try #require(projected.transcript[0].speakerID)
        #expect(target != cluster)
        #expect(Set(projected.associatedPersonIDs) == [firstPerson, secondPerson])
        #expect(projected.speakers.contains { $0.id == cluster })
        #expect(await store.assignSpeaker(meetingID: meeting.id, speakerID: target, personID: secondPerson))
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        let corrected = try #require(store.meeting(id: meeting.id))
        #expect(corrected.transcript.allSatisfy { $0.speakerID == cluster })
        #expect(corrected.speakers.first { $0.id == cluster }?.personID == secondPerson)
        #expect(corrected.associatedPersonIDs == [secondPerson])
        #expect(store.voiceLibrary.examples.allSatisfy { $0.review != .confirmed && $0.personID == nil })
        #expect(store.people.allSatisfy { $0.voiceSamples.isEmpty })
        #expect(store.voiceLibrary.undo())
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id], recomputeSuggestions: false)
        let restored = try #require(store.meeting(id: meeting.id))
        #expect(restored.transcript.map(\.speakerID) == projected.transcript.map(\.speakerID))
        #expect(restored.speakers.first { $0.id == restored.transcript[0].speakerID }?.personID == firstPerson)
        #expect(restored.speakers.first { $0.id == restored.transcript[1].speakerID }?.personID == secondPerson)
        #expect(Set(restored.associatedPersonIDs) == [firstPerson, secondPerson])
        let reopened = try MeetingFolderStorage.read(id: meeting.id, directory: directory)
        #expect(reopened.transcript == restored.transcript)
        #expect(Set(reopened.associatedPersonIDs) == [firstPerson, secondPerson])
    }

    @Test(arguments: [false, true])
    func overlappingTurnContextCannotReuseEarlierNamedProjection(samePerson: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, first) = try fixture(directory: directory)
        let clusterID = meeting.speakers[0].id
        meeting.speakers[0].independentTurnAttribution = true
        meeting.transcript = [
            .init(start: 0, end: 2, text: "First", speakerID: clusterID),
            .init(start: 2, end: 4, text: "Second", speakerID: clusterID),
        ]
        let person = UUID()
        first.personID = nil
        first.review = .suggested
        first.attributionTurn = .init(start: 0, end: 4)
        first.transcriptAssociation = .init(personID: person, score: 0.9, margin: 0.3, policy: .default)
        var other = first
        other.id = UUID()
        other.attributionTurn = .init(start: 2, end: 4)
        other.transcriptAssociation?.personID = samePerson ? person : UUID()
        other.transcriptAssociation?.tier = .tentative
        other.transcriptAssociation?.score = 0.6
        let projected = VoiceDecisionProjection.apply(
            to: meeting, evidence: [first, other], decisions: [], deletedPeople: [])
        #expect(projected.speakers.first { $0.id == projected.transcript[0].speakerID }?.personID == person)
        let overlap = projected.speakers.first { $0.id == projected.transcript[1].speakerID }
        #expect(overlap?.personID == (samePerson ? person : nil))
        if samePerson {
            #expect(overlap?.voiceReviewOrigin?.transcriptAssociationTier == .tentative)
            #expect(overlap?.attendancePersonID == nil)
        }
        #expect(projected.transcript[0].speakerID != projected.transcript[1].speakerID)
        #expect(
            VoiceDecisionProjection.apply(to: projected, evidence: [first, other], decisions: [], deletedPeople: [])
                == projected)
    }

    @Test func confirmedTurnReferenceCannotResolveIndependentAcousticUncertainty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, example) = try fixture(directory: directory)
        meeting.speakers[0].independentTurnAttribution = true
        meeting.transcript[0].associationUncertain = true
        example.attributionTurn = .init(start: 0, end: 2)
        let projected = VoiceDecisionProjection.apply(
            to: meeting, evidence: [example], decisions: [], deletedPeople: [])
        let speaker = projected.speakers.first { $0.id == projected.transcript[0].speakerID }
        #expect(speaker?.personID == nil)
        #expect(!projected.transcript[0].allowsPersonAssociation(from: speaker))
        #expect(projected.transcript[0].associationUncertain == true)
    }

    @Test func staleRejectedAndPartialTurnEvidenceLeavesRowsUnidentified() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (meeting, sample) = try fixture(directory: directory)
        meeting.speakers[0].independentTurnAttribution = true
        let person = UUID()
        sample.personID = nil
        sample.review = .suggested
        sample.attributionTurn = .init(start: 0, end: 2)
        sample.transcriptAssociation = .init(personID: person, score: 0.9, margin: 0.3, policy: .default)
        for kind in ["partial", "rejected", "policy", "deleted", "source"] {
            var invalid = sample
            var policy = VoiceMatchingPolicy.default
            if kind == "partial" { invalid.attributionTurn?.end = 1 }
            if kind == "rejected" { invalid.rejectedPersonIDs = [person] }
            if kind == "policy" { policy.automaticThreshold = 0.95 }
            if kind == "source" { invalid.audioFile = "microphone.wav" }
            let projected = VoiceDecisionProjection.apply(
                to: meeting, evidence: [invalid], decisions: [], deletedPeople: kind == "deleted" ? [person] : [],
                policy: policy)
            #expect(projected.transcript == meeting.transcript)
            #expect(projected.speakers.allSatisfy { $0.personID == nil })
        }
    }

    private func fixture(directory: URL) throws -> (Meeting, VoiceExample) {
        var meeting = Meeting(title: "Projection fixture", audioFiles: ["system.wav"])
        let speaker = MeetingSpeaker(label: "Speaker 1", track: "system", providerName: "Synthetic")
        meeting.speakers = [speaker]
        meeting.transcript = [.init(start: 0, end: 2, text: "Synthetic passage", speakerID: speaker.id)]
        let folder = try MeetingFolderLocation.newFolder(id: meeting.id, date: meeting.createdAt, directory: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("system.wav")
        try Data("synthetic audio".utf8).write(to: file)
        let example = VoiceExample(
            meetingID: meeting.id, speakerID: speaker.id, source: "system", audioFile: "system.wav",
            audioRevision: VoiceLibraryStore.revision(url: file), start: 0, end: 2,
            personID: UUID(), review: .confirmed)
        return (meeting, example)
    }

    @Test func unrelatedEvidencePreservesCachedProjectionAndAffectedEvidenceInvalidatesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (meeting, example) = try fixture(directory: directory)
        let (_, unrelated) = try fixture(directory: directory)
        #expect(library.upsert([example, unrelated]))
        let first = try #require(await library.projectedDecisions(to: meeting))
        #expect(first.speakers.first?.personID == example.personID)
        let count = library.projectionComputationCount
        #expect(library.confirm(ids: [unrelated.id], personID: UUID()))
        #expect(await library.projectedDecisions(to: meeting) == first)
        #expect(library.applyingDecisions(to: first) == first)
        #expect(library.projectionComputationCount == count)
        let replacement = UUID()
        #expect(library.confirm(ids: [example.id], personID: replacement))
        let changed = try #require(await library.projectedDecisions(to: first))
        #expect(changed.speakers.first?.personID == replacement)
        #expect(library.projectionComputationCount == count + 1)
    }

    @Test func unreviewedMeetingReturnsWithoutStartingProjectionWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let meeting = Meeting(title: "Unreviewed fixture")
        #expect(library.applyingDecisions(to: meeting) == meeting)
        #expect(await library.projectedDecisions(to: meeting) == meeting)
        #expect(library.projectionComputationCount == 0)
    }

    @Test func workerYieldsMainActorAndDiscardsChangedEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (meeting, example) = try fixture(directory: directory)
        #expect(library.upsert([example]))
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        library.beforeProjectionRead = {
            #expect(!Thread.isMainThread)
            continuation.yield(())
            release.wait()
        }
        let projection = Task { await library.projectedDecisions(to: meeting) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let replacement = UUID()
        #expect(library.confirm(ids: [example.id], personID: replacement))
        library.beforeProjectionRead = nil
        release.signal()
        #expect(await projection.value == nil)
        let current = try #require(await library.projectedDecisions(to: meeting))
        #expect(current.speakers.first?.personID == replacement)
    }

    @Test func audioReconciliationInvalidatesProjectionBeforeRecheckingEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (meeting, example) = try fixture(directory: directory)
        #expect(library.upsert([example]))
        let projected = try #require(await library.projectedDecisions(to: meeting))
        let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: directory)
        try Data("replacement synthetic recording".utf8).write(to: folder.appendingPathComponent("system.wav"))
        library.invalidateDecisionProjections(
            paths: [folder.appendingPathComponent("system.wav")], root: directory, rebuild: false)
        let restored = try #require(await library.projectedDecisions(to: projected))
        #expect(restored.speakers.first?.personID == nil)
        #expect(restored.transcript.first?.speakerID == meeting.speakers.first?.id)
    }
    @Test(arguments: [false, true])
    func queuedCommitRejectsMeetingOrEvidenceChangedByEarlierCommand(changeEvidence: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let (fixtureMeeting, example) = try fixture(directory: directory)
        try await store.insertImportedMeeting(fixtureMeeting)
        // Canonical insertion allocates speaker colors. Use the saved input so
        // this test isolates changes made by the queued command.
        let meeting = try #require(store.meeting(id: fixtureMeeting.id))
        let library = store.voiceLibrary
        #expect(await library.awaitReady())
        library.didChange = nil
        library.didChangeProjection = nil
        // Readiness schedules a repair independently of didChange. Drain it
        // while the library is empty so this test owns the only projection
        // commit and can assert that rejecting it publishes nothing.
        await store.flushVoiceAssignmentRefresh()
        #expect(library.upsert([example]))
        let projection = try #require(await library.decisionProjection(to: meeting))
        #expect(projection.meeting != meeting)
        #expect(library.isCurrentDecisionProjection(projection.token))
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let replacementPerson = UUID()
        let earlier = Task {
            await store.enqueueCanonical {
                enteredContinuation.yield(())
                var releaseIterator = release.makeAsyncIterator()
                _ = await releaseIterator.next()
                if changeEvidence {
                    return library.confirm(ids: [example.id], personID: replacementPerson)
                }
                guard let index = store.meetings.firstIndex(where: { $0.id == meeting.id }) else { return false }
                store.meetings[index].title = "Changed while queued"
                return true
            }
        }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()
        let commit = Task { await store.commitVoiceProjection(projection, expected: meeting, library: library) }
        await Task.yield()
        releaseContinuation.yield(())
        #expect(await earlier.value)
        #expect(await commit.value == .stale)
        #expect(store.meeting(id: meeting.id)?.speakers == meeting.speakers)
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id])
        let current = try #require(store.meeting(id: meeting.id))
        #expect(current.speakers.first?.personID == (changeEvidence ? replacementPerson : example.personID))
        #expect(current.title == (changeEvidence ? meeting.title : "Changed while queued"))
        let reopened = try MeetingFolderStorage.read(id: meeting.id, directory: directory)
        #expect(reopened.title == current.title)
        #expect(reopened.speakers == current.speakers)
    }

    @Test func projectionTokenSurvivesCacheEvictionAndRejectsAudioInvalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var meetings: [Meeting] = []
        var examples: [VoiceExample] = []
        for _ in 0..<24 {
            let (meeting, example) = try fixture(directory: directory)
            meetings.append(meeting)
            examples.append(example)
        }
        #expect(library.upsert(examples))
        var projections: [VoiceLibraryStore.DecisionProjection] = []
        for meeting in meetings {
            projections.append(try #require(await library.decisionProjection(to: meeting)))
        }
        // At least eight results have left the sixteen-entry cache. Every token
        // remains valid because none of their evidence generations changed.
        #expect(projections.allSatisfy { library.isCurrentDecisionProjection($0.token) })
        library.invalidateDecisionProjections(meetingIDs: [meetings[0].id])
        #expect(!library.isCurrentDecisionProjection(projections[0].token))
        #expect(projections.dropFirst().allSatisfy { library.isCurrentDecisionProjection($0.token) })
    }

    @Test(arguments: ["deleting", "recording", "evicted"])
    func ineligibleMeetingDoesNotDiscardOtherMeetingRefreshes(_ reason: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        var fixtures: [(Meeting, VoiceExample)] = []
        for _ in 0..<2 {
            let (meeting, example) = try fixture(directory: directory)
            try await store.insertImportedMeeting(meeting)
            fixtures.append((meeting, example))
        }
        fixtures.sort { $0.0.id.uuidString < $1.0.id.uuidString }
        let first = fixtures[0].0
        let second = fixtures[1].0
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        #expect(library.upsert(fixtures.map { $0.1 }))
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        library.beforeProjectionRead = {
            continuation.yield(())
            release.wait()
        }
        let refresh = Task { await store.refreshVoiceAssignments(meetingIDs: [first.id, second.id]) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        switch reason {
        case "deleting": store.deletingMeetingIDs.insert(first.id)
        case "recording": store.recordingID = first.id
        default: store.meetings.removeAll { $0.id == first.id }
        }
        library.beforeProjectionRead = nil
        release.signal()
        await refresh.value
        #expect(store.meeting(id: second.id)?.speakers.first?.personID == fixtures[1].1.personID)
        let saved = try MeetingFolderStorage.read(id: second.id, directory: directory)
        #expect(saved.speakers.first?.personID == fixtures[1].1.personID)
    }

    @Test func invalidationPathsTargetReferencedAudioAndHandleAncestorRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let (first, example) = try fixture(directory: directory)
        let (second, other) = try fixture(directory: directory)
        #expect(library.upsert([example, other]))
        let folder = try MeetingFolderLocation.resolve(id: first.id, directory: directory)
        let prepared = try #require(await library.decisionProjection(to: first))
        let count = library.projectionComputationCount
        for entry in [".DS_Store", "unfinished-import"] {
            #expect(
                library.invalidateDecisionProjections(
                    paths: [directory.appendingPathComponent("meetings/" + entry)], root: directory, rebuild: false
                ).isEmpty)
        }
        #expect(library.isCurrentDecisionProjection(prepared.token))
        #expect(await library.projectedDecisions(to: first) == prepared.meeting)
        #expect(library.projectionComputationCount == count)
        #expect(
            library.invalidateDecisionProjections(
                paths: [folder.appendingPathComponent("meeting.json")], root: directory, rebuild: false
            ).isEmpty)
        #expect(library.invalidateDecisionProjections(paths: [folder], root: directory, rebuild: false) == [first.id])
        let audio = folder.appendingPathComponent("system.wav")
        let alias = URL(fileURLWithPath: audio.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        #expect(library.invalidateDecisionProjections(paths: [alias], root: directory, rebuild: false) == [first.id])
        #expect(
            library.invalidateDecisionProjections(paths: [directory], root: directory, rebuild: false) == [
                first.id, second.id,
            ])
        let malformed = directory.appendingPathComponent("meetings/invalid-folder/system.wav")
        #expect(
            library.invalidateDecisionProjections(paths: [malformed], root: directory, rebuild: false) == [
                first.id, second.id,
            ])
        #expect(
            library.invalidateDecisionProjections(paths: [], root: directory, rebuild: true) == [first.id, second.id])
    }

    @Test func backgroundSuggestionChangesPreserveProjectionGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        var (meeting, example) = try fixture(directory: directory)
        let rejectedPerson = UUID()
        example.personID = nil
        example.review = .rejected
        example.rejectedPersonIDs = [rejectedPerson]
        meeting.speakers[0].personID = rejectedPerson
        #expect(library.upsert([example]))
        let projection = try #require(await library.decisionProjection(to: meeting))
        let count = library.projectionComputationCount
        #expect(library.suggest(exampleID: example.id, personID: UUID()))
        #expect(library.isCurrentDecisionProjection(projection.token))
        #expect(await library.projectedDecisions(to: meeting) == projection.meeting)
        #expect(library.projectionComputationCount == count)
    }

    @Test func cancelledQueuedProjectionDoesNotPublishOrPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let (fixtureMeeting, example) = try fixture(directory: directory)
        try await store.insertImportedMeeting(fixtureMeeting)
        let meeting = try #require(store.meeting(id: fixtureMeeting.id))
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        #expect(library.upsert([example]))
        let projection = try #require(await library.decisionProjection(to: meeting))
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let earlier = Task {
            await store.enqueueCanonical {
                enteredContinuation.yield(())
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
                return true
            }
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        let commit = Task { await store.commitVoiceProjection(projection, expected: meeting, library: library) }
        await Task.yield()
        commit.cancel()
        releaseContinuation.yield(())
        #expect(await earlier.value)
        #expect(await commit.value == .stopped)
        #expect(store.meeting(id: meeting.id) == meeting)
        #expect(try MeetingFolderStorage.read(id: meeting.id, directory: directory).speakers == meeting.speakers)
    }

    @Test func monitoredAudioReplacementRefreshesLoadedProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let (meeting, example) = try fixture(directory: directory)
        try await store.insertImportedMeeting(meeting)
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        #expect(library.upsert([example]))
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id])
        #expect(store.meeting(id: meeting.id)?.speakers.first?.personID == example.personID)
        store.startLibraryMonitoring()
        let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: directory)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("replacement synthetic source".utf8).write(to: audio)
        store.libraryMonitor?.process(.init(paths: [audio], requiresScan: false, eventID: 0))
        let restored = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            store.meeting(id: meeting.id)?.speakers.first?.personID == nil
        }
        await store.flushVoiceAssignmentRefresh()
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        #expect(restored)
        #expect(try MeetingFolderStorage.read(id: meeting.id, directory: directory).speakers.first?.personID == nil)
    }

    @Test func failedScopedProjectionSaveRestoresOwnedMeetingState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let (fixtureMeeting, example) = try fixture(directory: directory)
        try await store.insertImportedMeeting(fixtureMeeting)
        let meeting = try #require(store.meeting(id: fixtureMeeting.id))
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        #expect(library.upsert([example]))
        let projection = try #require(await library.decisionProjection(to: meeting))
        store.canonicalWriteHook = { throw ServiceError("Synthetic save failure") }
        #expect(await store.commitVoiceProjection(projection, expected: meeting, library: library) == .failed)
        #expect(store.meeting(id: meeting.id) == meeting)
        #expect(try MeetingFolderStorage.read(id: meeting.id, directory: directory).speakers == meeting.speakers)
    }

    @Test func filesystemProjectionRefreshPreservesSuggestionsAndCoalescedDecisionStillRematches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Sample Person")
        let (meeting, fixtureReference) = try fixture(directory: directory)
        var reference = fixtureReference
        reference.personID = person
        var candidate = reference
        candidate.id = UUID()
        candidate.start = 3
        candidate.end = 4
        candidate.personID = nil
        candidate.suggestedPersonID = person
        candidate.review = .suggested
        try await store.insertImportedMeeting(meeting)
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        #expect(library.upsert([reference, candidate]))
        #expect(await store.refreshLoadedVoiceAssignment(id: meeting.id, library: library) == .committed)
        #expect(library.examples.first { $0.id == candidate.id }?.suggestedPersonID == person)
        store.startLibraryMonitoring()
        let folder = try MeetingFolderLocation.resolve(id: meeting.id, directory: directory)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("replacement synthetic source".utf8).write(to: audio)
        store.libraryMonitor?.process(.init(paths: [audio], requiresScan: false, eventID: 0))
        let restored = try await waitForMainActorTestCondition(timeout: .seconds(5)) {
            store.meeting(id: meeting.id)?.speakers.first?.personID == nil
        }
        await store.flushVoiceAssignmentRefresh()
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        #expect(restored)
        #expect(library.examples.first { $0.id == candidate.id }?.suggestedPersonID == person)
        // A decision's matching request survives filesystem requests coalesced
        // before and after it. This fixture has no matching enrolled vectors.
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [meeting.id], recomputeSuggestions: false)
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [meeting.id])
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [meeting.id], recomputeSuggestions: false)
        await store.flushVoiceAssignmentRefresh()
        #expect(library.examples.first { $0.id == candidate.id }?.suggestedPersonID == nil)
    }

    @Test func decisionArrivingDuringFilesystemProjectionRematchesInFollowingBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Sample Person")
        let (meeting, fixtureReference) = try fixture(directory: directory)
        var reference = fixtureReference
        reference.personID = person
        var candidate = reference
        candidate.id = UUID()
        candidate.start = 3
        candidate.end = 4
        candidate.personID = nil
        candidate.suggestedPersonID = person
        candidate.review = .suggested
        try await store.insertImportedMeeting(meeting)
        let library = store.voiceLibrary
        library.didChange = nil
        library.didChangeProjection = nil
        #expect(library.upsert([reference, candidate]))
        #expect(await store.refreshLoadedVoiceAssignment(id: meeting.id, library: library) == .committed)
        library.invalidateDecisionProjections(meetingIDs: [meeting.id])
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        library.beforeProjectionRead = {
            continuation.yield(())
            release.wait()
        }
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [meeting.id], recomputeSuggestions: false)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        // The first batch already consumed its false intent and is suspended on
        // the worker. A decision and another file event belong to the next batch.
        #expect(library.examples.first { $0.id == candidate.id }?.suggestedPersonID == person)
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [meeting.id])
        store.scheduleVoiceAssignmentRefresh(meetingIDs: [meeting.id], recomputeSuggestions: false)
        library.beforeProjectionRead = nil
        release.signal()
        await store.flushVoiceAssignmentRefresh()
        #expect(library.examples.first { $0.id == candidate.id }?.suggestedPersonID == nil)
    }

}
